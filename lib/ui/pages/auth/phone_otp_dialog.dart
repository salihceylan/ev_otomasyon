import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../models/api_models.dart';
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
import '../../theme/tokens.dart';

/// Telefon numarasıyla şifresiz giriş (SMS kodu).
///
/// * Telefon doğrulanır ve ayırıcılardan arındırılarak (`+905551234567` / `05551234567`) gönderilir.
/// * "Yeniden gönder", sunucunun `resend_after` süresi dolana kadar kapalıdır (429'da
///   `resend_after` / `retry_after` ile de); kodun geçerlilik süresi geri sayılır. Yeniden gönderim başarısız
///   olursa kod adımı korunur: önceki kod hâlâ geçerlidir, yalnız hata iletisi gösterilir.
/// * Hatalı kodda kalan deneme hakkı (`remaining_attempts`) gösterilir; deneme bitince bekleme.
///
/// Görünüm: auth/onay akışının ORTAK diyalog kabuğu ([AuthDialogShell]). İki alan (telefon, kod) aynı alan
/// dilini kullanır: soluk 14 sp etiket, çizgisel soluk ön ek simgesi, aynı çerçeve; kilitli telefon alanı etkin
/// kod alanından daha soluk çerçevelidir.
class PhoneOtpDialog extends StatefulWidget {
  const PhoneOtpDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showAppDialog(context, barrierDismissible: false, builder: (_) => const PhoneOtpDialog());
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

  /// `true`: [_error] KOD alanıyla ilgilidir (eksik/hatalı/süresi dolmuş kod): alan kırmızı çizilir. Yeniden
  /// gönderim hatası koda ait değildir (önceki kod hâlâ geçerli): alan hatalı çizilmez, yalnız ileti gösterilir.
  bool _codeError = false;
  String? _info;

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
      _codeError = false;
      _info = null;
    });
    try {
      final state = context.read<AutomationState>();
      final CodeChallenge challenge = await state.sendPhoneOtp(phone);
      if (!mounted) return;
      setState(() {
        _isCodeSent = true;
        _phone = phone;
        _codeController.clear();
        _info = challenge.message.isNotEmpty ? challenge.message : 'Doğrulama kodu gönderildi.';
      });
      _resend.start(challenge.resendAfter);
      final expiresIn = challenge.expiresIn;
      _hasExpiry = expiresIn != null;
      if (expiresIn != null) _expiry.start(expiresIn);
    } catch (e) {
      if (!mounted) return;
      // Yeniden gönderim başarısızsa (saatlik sınır, 503, ağ) kod adımı KORUNUR: önceki kod sunucuda hâlâ geçerlidir
      // (sunucu onu yalnız yeni kod üretince tüketir); kod alanı ve "Giriş Yap" kalır, yalnız hata iletisi (UYELIK-01).
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
      setState(() {
        _error = codeError;
        _codeError = true;
      });
      return;
    }
    setState(() {
      _isLoading = true;
      _error = null;
      _codeError = false;
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
          text =
              'Çok fazla hatalı deneme yapıldı. '
              '${wait == null ? 'Biraz bekleyip' : '${formatCountdown(wait.inSeconds)} sonra'} yeni kod isteyin.';
          if (wait != null) _resend.start(wait);
        }
      }
      // Kalan hak TEK yerde: iletinin içinde (bölünmeyen boşlukla; "2." yetim kalmaz). Alan altında ikinci satır yok.
      setState(() {
        _error = remaining == null ? text : '$text ${remainingAttemptsText(remaining)}';
        _codeError = true;
      });
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final muted = AppTheme.getTextMuted(context);
    final primary = AppTheme.getTextPrimary(context);
    // Hata iletisi: kod adımındayken (kod alanı görünür) hata o alanındır ve alanın HEMEN altında durur (eskiden
    // geri sayım satırının altında, alandan ~95 dp uzaktaydı); telefon adımında formun sonundadır.
    final errorBox = _error == null ? null : InlineMessage.error(_error!, key: const Key('otp_error'));
    return PopScope(
      canPop: !_isLoading,
      child: AuthDialogShell(
        icon: Icons.sms_rounded,
        family: AppFamilies.violet,
        title: 'Şifresiz SMS Girişi',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              !_isCodeSent
                  ? 'Telefon numaranızı girin, size 6 haneli tek kullanımlık doğrulama kodu gönderelim.'
                  : '${_info ?? 'Doğrulama kodu gönderildi.'} $_phone numarasına gelen 6 haneli kodu girin.',
              key: const Key('otp_info'),
              style: TextStyle(color: muted, fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 18),
            TextField(
              key: const Key('field_phone'),
              controller: _phoneController,
              enabled: !_isCodeSent && !_isLoading,
              keyboardType: TextInputType.phone,
              autofillHints: const [AutofillHints.telephoneNumber],
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9+\-\s().]')), LengthLimitingTextInputFormatter(20)],
              onChanged: (_) {
                if (_phoneError != null) setState(() => _phoneError = null);
              },
              onSubmitted: (_) => _handleSendCode(),
              style: TextStyle(color: primary, fontSize: 15),
              decoration: authInputDecoration(
                context,
                label: 'Telefon Numarası',
                hint: '0555 123 45 67',
                prefixIcon: Icons.phone_outlined,
                errorText: _phoneError,
              ),
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
                style: authCodeTextStyle(context),
                // Kod hatası varken alan KIRMIZI çizilir (odak halkası cyan kalıp yanlış kodu "geçerli" göstermesin);
                // yeniden gönderim hatasında çizilmez (önceki kod hâlâ geçerli).
                decoration: authCodeInputDecoration(
                  context,
                  label: 'Doğrulama Kodu',
                  hint: '••••••',
                  hasError: errorBox != null && _codeError,
                ),
              ),
              if (errorBox != null) ...[const SizedBox(height: 8), errorBox],
              const SizedBox(height: 8),
              // Wrap: dar ekranda / büyük yazıda "Tekrar Kod İste" düğmesi alt satıra geçer (Row taşardı).
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: [
                  ValueListenableBuilder<int>(
                    valueListenable: _expiry.remaining,
                    builder: (context, seconds, _) {
                      final active = seconds > 0;
                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (active) ...[
                            CooldownArc(remaining: _expiry.remaining, color: AppTheme.infoText(context)),
                            const SizedBox(width: 6),
                          ],
                          Flexible(
                            child: Text(
                              active ? 'Kod süresi: ${formatCountdown(seconds)}' : (_hasExpiry ? 'Kodun süresi doldu' : ''),
                              key: const Key('otp_expiry'),
                              style: TextStyle(
                                color: (_hasExpiry && !active) ? AppTheme.dangerText(context) : muted,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  TextButton(
                    key: const Key('btn_resend_code'),
                    // Yeni kod isteği (telefon aynı). Kod adımı istekten ÖNCE kapatılmaz: başarıda kod alanı temizlenir
                    // (yeni kod), başarısızlıkta alan ve "Giriş Yap" kalır (önceki kod hâlâ geçerli; UYELIK-01).
                    onPressed: (_isLoading || _resend.isActive) ? null : _handleSendCode,
                    style: TextButton.styleFrom(padding: EdgeInsets.zero),
                    child: ValueListenableBuilder<int>(
                      valueListenable: _resend.remaining,
                      builder: (context, seconds, _) => Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (seconds > 0) ...[CooldownArc(remaining: _resend.remaining, color: muted), const SizedBox(width: 6)],
                          Flexible(
                            child: Text(
                              seconds > 0 ? 'Tekrar Kod İste (${formatCountdown(seconds)})' : 'Tekrar Kod İste',
                              // Bekleme sürerken düğme pasif: bağlantı rengi değil soluk metin (çelişkili sinyal yok).
                              style: TextStyle(color: seconds > 0 ? muted : AppTheme.infoText(context), fontSize: 12, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (!_isCodeSent && errorBox != null) ...[const SizedBox(height: 8), errorBox],
          ],
        ),
        actions: AuthDialogActions(
          secondaryLabel: 'İptal',
          secondary: TextButton(
            key: const Key('btn_otp_cancel'),
            onPressed: _isLoading ? null : () => Navigator.of(context).pop(),
            child: authSecondaryLabel(context, 'İptal'),
          ),
          primaryLabel: 'Kod Gönder',
          primary: ElevatedButton(
            key: Key(_isCodeSent ? 'btn_otp_verify' : 'btn_otp_send'),
            onPressed: _isLoading ? null : (!_isCodeSent ? (_resend.isActive ? null : _handleSendCode) : _handleVerifyCode),
            child: _isLoading ? buttonSpinner() : authPrimaryLabel(!_isCodeSent ? 'Kod Gönder' : 'Giriş Yap'),
          ),
        ),
      ),
    );
  }
}
