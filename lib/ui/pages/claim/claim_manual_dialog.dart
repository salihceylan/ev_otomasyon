import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../models/capabilities.dart';
import '../../../models/json_utils.dart';
import '../../../services/automation_state.dart';
import '../../../utils/friendly_error.dart';
import '../../../utils/qr_claim_parser.dart';
import '../../common/cooldown.dart';
import '../../common/date_format.dart';
import '../../common/inline_message.dart';
import '../../common/validators.dart';
import '../../theme/app_theme.dart';

String _humanDuration(Duration d) {
  final seconds = d.inSeconds;
  if (seconds >= 120) return '${(seconds / 60).ceil()} dakika';
  return '$seconds saniye';
}

/// Claim hatalarını eyleme yönelik Türkçe mesaja çevirir (ham istisna metni gösterilmez).
///
/// 423 `PIN_LOCKED` (`retry_after`), 429, 409, 403, doğrulama/kalan deneme ve ağ hataları ayrı ele alınır.
String claimErrorMessage(Object error) {
  if (error is ApiException) {
    if (error.isPinLocked) {
      final wait = error.retryAfter;
      return 'Çok fazla hatalı PIN denemesi yapıldı; bu cihaz geçici olarak kilitlendi. '
          '${wait == null ? 'Bir süre' : _humanDuration(wait)} sonra tekrar deneyin.';
    }
    if (error.isRateLimited) {
      final wait = error.retryAfter ?? error.resendAfter;
      return 'Çok fazla istek gönderildi. ${wait == null ? 'Biraz' : _humanDuration(wait)} bekleyip tekrar deneyin.';
    }
    if (error.statusCode == 409) {
      return 'Bu cihaz zaten bir daireye bağlı veya işlem çakıştı. Cihaz önceki sahibine aitse '
          'devir kodu alın ya da servisle iletişime geçin.';
    }
    if (error.isForbidden) {
      return 'Bu işlem için yetkiniz yok veya bu cihazı eşleştiremezsiniz.';
    }
    if (error.isInvalidCredentials || error.isValidation) {
      final remaining = error.remainingAttempts;
      return remaining == null ? error.message : '${error.message} Kalan deneme: $remaining.';
    }
    if (error.isNetwork) {
      return 'Sunucuya ulaşılamadı. İnternet bağlantınızı kontrol edip tekrar deneyin.';
    }
    return error.message;
  }
  return friendlyError(error, fallback: 'Eşleştirme tamamlanamadı. Lütfen tekrar deneyin.');
}

/// Cihaz eşleştirme (claim) diyaloğu: pano etiketindeki UID + 6 haneli kurulum PIN'i.
///
/// * `show` diyaloğu **dışarı dokunarak kapanmaz** (`barrierDismissible: false`); istek sürerken geri
///   tuşu da kapatmaz (`PopScope`).
/// * UID normalleştirilir (kırp + büyük harf + `AHBU-...` deseni), PIN yalnızca 6 rakamdır.
/// * Çift dokunuşa karşı korumalıdır (istek sürerken ikinci istek gitmez).
/// * Hata kodları Türkçe ve eyleme yönelik eşlenir: 423 `PIN_LOCKED` (`retry_after` geri sayımı),
///   429, 409, 403, ağ. Ham istisna metni gösterilmez.
/// * Servis personeli / süper kullanıcı **müşteri adına** eşleyebilir: müşteri e-posta/telefon + OTP;
///   OTP gönderildikten sonra alanlar kilitlenir ve kendi kimliğini hedef olarak giremez.
class ClaimManualDialog extends StatefulWidget {
  final String? initialUid;
  final String? initialPin;

  const ClaimManualDialog({
    super.key,
    this.initialUid,
    this.initialPin,
  });

  static Future<bool?> show(
    BuildContext context, {
    String? initialUid,
    String? initialPin,
  }) {
    final state = context.read<AutomationState>();
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => ChangeNotifierProvider<AutomationState>.value(
        value: state,
        child: ClaimManualDialog(
          initialUid: initialUid,
          initialPin: initialPin,
        ),
      ),
    );
  }

  @override
  State<ClaimManualDialog> createState() => _ClaimManualDialogState();
}

class _ClaimManualDialogState extends State<ClaimManualDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _uidController;
  late final TextEditingController _pinController;
  late final TextEditingController _homeNameController;
  final _customerController = TextEditingController();
  final _otpController = TextEditingController();

  bool _obscurePin = true;
  bool _isLoading = false;

  // Müşteri adına eşleme (yalnızca servis personeli / süper kullanıcı)
  bool _forCustomer = false;
  bool _otpSent = false;
  bool _otpSending = false;
  late final Cooldown _resend;
  late final Cooldown _pinLock;

  String? _error;
  _ClaimSuccessView? _success;

  @override
  void initState() {
    super.initState();
    final state = context.read<AutomationState>();
    _uidController = TextEditingController(text: widget.initialUid ?? '');
    _pinController = TextEditingController(text: widget.initialPin ?? '');
    _homeNameController = TextEditingController(text: 'Evim');
    _resend = Cooldown(state.clock, _refresh);
    _pinLock = Cooldown(state.clock, _refresh);
    // Kalıcı servis personeli (küresel `service_user`) kendi adına cihaz sahiplenemez (sunucu 400
    // reddeder): müşteri adına eşleme baştan açık ve kapatılamaz.
    _forCustomer = _mustActForCustomer(state);
  }

  static bool _mustActForCustomer(AutomationState state) =>
      GlobalRole.parse(state.currentUser?.role) == GlobalRole.serviceUser;

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _resend.dispose();
    _pinLock.dispose();
    _uidController.dispose();
    _pinController.dispose();
    _homeNameController.dispose();
    _customerController.dispose();
    _otpController.dispose();
    super.dispose();
  }

  bool get _fieldsLocked => _otpSent || _isLoading;

  // ---------------------------------------------------------------------------
  // Hata eşleme
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // İşlemler
  // ---------------------------------------------------------------------------

  /// Müşteri hedefi: geçerli e-posta/telefon ve **kendi kimliği değil**.
  String? _customerError(AutomationState state) {
    final text = _customerController.text.trim();
    final parsed = AuthValidators.parseIdentifier(text);
    if (parsed == null) return 'Müşterinin geçerli e-posta veya telefon numarasını girin';
    final me = state.currentUser;
    if (me != null) {
      final myEmail = me.email.trim().toLowerCase();
      final myPhone = AuthValidators.normalizePhone(me.phone);
      if ((parsed.isEmail && myEmail.isNotEmpty && parsed.value == myEmail) ||
          (parsed.isPhone && myPhone != null && parsed.value == myPhone)) {
        return 'Kendi hesabınıza eşleme yapamazsınız; müşterinin bilgilerini girin';
      }
    }
    return null;
  }

  Future<void> _sendOtp() async {
    if (_otpSending || _isLoading || _resend.isActive) return;
    final state = context.read<AutomationState>();
    final uid = QrClaimParser.normalizeUid(_uidController.text);
    if (uid == null) {
      setState(() => _error = 'Önce geçerli bir cihaz kimliği (UID) girin.');
      return;
    }
    final customerError = _customerError(state);
    if (customerError != null) {
      setState(() => _error = customerError);
      return;
    }
    final target = AuthValidators.parseIdentifier(_customerController.text)!.value;
    setState(() {
      _otpSending = true;
      _error = null;
    });
    try {
      final res = await state.requestClaimOtp(deviceUuid: uid, targetOwner: target);
      if (!mounted) return;
      final resendSeconds = asInt(res['resend_after']) ?? 60;
      setState(() {
        _otpSent = true;
        _otpSending = false;
      });
      _resend.start(Duration(seconds: resendSeconds > 0 ? resendSeconds : 60));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _otpSending = false;
        _error = claimErrorMessage(e);
      });
      if (e is ApiException) {
        final wait = e.resendAfter ?? e.retryAfter;
        if (wait != null) _resend.start(wait);
      }
    }
  }

  void _unlockFields() {
    setState(() {
      _otpSent = false;
      _otpController.clear();
      _error = null;
    });
  }

  Future<void> _handleClaim() async {
    if (_isLoading) return; // çift dokunuş koruması (senkron)
    if (_pinLock.isActive) return;
    if (!_formKey.currentState!.validate()) return;
    final state = context.read<AutomationState>();

    final uid = QrClaimParser.normalizeUid(_uidController.text);
    if (uid == null) return; // doğrulayıcı zaten reddetti
    final pin = _pinController.text.trim();

    String? targetOwner;
    String? otp;
    if (_forCustomer) {
      final customerError = _customerError(state);
      if (customerError != null) {
        setState(() => _error = customerError);
        return;
      }
      if (!_otpSent) {
        setState(() => _error = 'Önce müşteriye doğrulama kodu gönderin.');
        return;
      }
      otp = _otpController.text.trim();
      if (!RegExp(r'^\d{6}$').hasMatch(otp)) {
        setState(() => _error = 'Müşterinin söylediği 6 haneli kodu girin.');
        return;
      }
      targetOwner = AuthValidators.parseIdentifier(_customerController.text)!.value;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final homeName = _homeNameController.text.trim();
      final res = await state.claimDevice(
        uid,
        pin,
        homeName: homeName.isNotEmpty ? homeName : 'Evim',
        targetOwner: targetOwner,
        otpCode: otp,
      );
      if (!mounted) return;
      final hasExtra = res.warnings.isNotEmpty || (res.customerAccount?.created ?? false);
      if (!hasExtra) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: const Text('Cihaz başarıyla evinize eşleştirildi.'),
            backgroundColor: AppTheme.accentGreen,
            behavior: SnackBarBehavior.floating,
          ),
        );
        Navigator.of(context).pop(true);
        return;
      }
      // Kısmi başarı uyarıları kullanıcıya gösterilir.
      setState(() {
        _isLoading = false;
        _success = _ClaimSuccessView(
          homeName: res.homeName,
          warnings: res.warnings,
          customerCreated: res.customerAccount?.created ?? false,
          inviteSent: res.customerAccount?.inviteSent ?? false,
          technicianUntil: res.technicianAccessExpiresAt,
        );
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = claimErrorMessage(e);
      });
      if (e is ApiException && (e.isPinLocked || e.isRateLimited)) {
        final wait = e.retryAfter ?? e.resendAfter;
        if (wait != null) _pinLock.start(wait);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Arayüz
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AutomationState>();
    final caps = state.capabilities;

    return PopScope(
      canPop: !_isLoading,
      child: AlertDialog(
        backgroundColor: AppTheme.getSurfaceColor(context),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: AppTheme.getCardBorder(context), width: 1.2),
        ),
        title: Row(
          children: [
            const Icon(Icons.qr_code_2_rounded, color: AppTheme.primaryBlueLight, size: 28),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                'Cihaz Eşleştirme',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.getTextPrimary(context)),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: SingleChildScrollView(
            child: !caps.canClaimDevice
                ? const InlineMessage.error('Bu hesapla cihaz eşleştiremezsiniz.', key: Key('claim_forbidden'))
                : (_success != null ? _buildSuccess(_success!) : _buildForm(context, state)),
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        actions: _success != null || !caps.canClaimDevice
            ? [
                ElevatedButton(
                  key: const Key('btn_claim_done'),
                  onPressed: () => Navigator.of(context).pop(_success != null),
                  child: const Text('Tamam'),
                ),
              ]
            : [
                TextButton(
                  key: const Key('btn_claim_cancel'),
                  onPressed: _isLoading ? null : () => Navigator.of(context).pop(false),
                  child: Text('İptal', style: TextStyle(color: AppTheme.getTextMuted(context))),
                ),
                ElevatedButton(
                  key: const Key('btn_claim_submit'),
                  onPressed: (_isLoading || _pinLock.isActive) ? null : _handleClaim,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryBlue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: _isLoading
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : Text(
                          _pinLock.isActive
                              ? 'Bekleyin (${formatCountdown(_pinLock.remainingSeconds)})'
                              : 'Eşle & Sahiplen',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                ),
              ],
      ),
    );
  }

  Widget _buildForm(BuildContext context, AutomationState state) {
    final caps = state.capabilities;
    final canActForCustomer = caps.isStaff || caps.isSuperUser;
    final mustActForCustomer = _mustActForCustomer(state);
    final locked = _fieldsLocked;
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Pano kapağındaki karekod bilgilerini kontrol edin veya seri numarasını elle girin.',
            style: TextStyle(color: AppTheme.getTextMuted(context), fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 18),
          TextFormField(
            key: const Key('field_claim_uid'),
            controller: _uidController,
            readOnly: locked,
            enabled: !_isLoading,
            textCapitalization: TextCapitalization.characters,
            autocorrect: false,
            enableSuggestions: false,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9\-]')),
              LengthLimitingTextInputFormatter(37),
              _UpperCaseFormatter(),
            ],
            style: TextStyle(color: AppTheme.getTextPrimary(context)),
            decoration: _inputDecoration(
              context,
              label: 'Cihaz UID / Seri No',
              hintText: 'Örn: AHBU-S3-1A2B3C',
              prefixIcon: Icons.fingerprint,
            ),
            validator: (val) {
              if (val == null || val.trim().isEmpty) return 'Lütfen cihaz seri numarasını (UID) girin';
              if (QrClaimParser.normalizeUid(val) == null) {
                return 'Geçerli bir cihaz kimliği girin (AHBU- ile başlar)';
              }
              return null;
            },
          ),
          const SizedBox(height: 14),
          TextFormField(
            key: const Key('field_claim_pin'),
            controller: _pinController,
            readOnly: locked,
            enabled: !_isLoading,
            obscureText: _obscurePin,
            keyboardType: TextInputType.number,
            autocorrect: false,
            enableSuggestions: false,
            maxLength: 6,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(6),
            ],
            style: TextStyle(
              color: AppTheme.getTextPrimary(context),
              letterSpacing: 4,
              fontWeight: FontWeight.bold,
            ),
            decoration: _inputDecoration(
              context,
              label: 'Kurulum PIN Kodu (6 Hane)',
              hintText: '••••••',
              prefixIcon: Icons.lock_outline,
              suffixIcon: IconButton(
                tooltip: _obscurePin ? 'PIN\'i göster' : 'PIN\'i gizle',
                icon: Icon(
                  _obscurePin ? Icons.visibility_off : Icons.visibility,
                  color: AppTheme.getTextMuted(context),
                ),
                onPressed: () => setState(() => _obscurePin = !_obscurePin),
              ),
            ),
            validator: (val) {
              if (val == null || val.trim().isEmpty) return 'Lütfen 6 haneli kurulum PIN kodunu girin';
              if (!QrClaimParser.isValidPin(val)) return 'PIN kodu tam 6 haneli olmalıdır';
              return null;
            },
          ),
          const SizedBox(height: 6),
          TextFormField(
            key: const Key('field_claim_home_name'),
            controller: _homeNameController,
            enabled: !_isLoading,
            maxLength: 60,
            style: TextStyle(color: AppTheme.getTextPrimary(context)),
            decoration: _inputDecoration(
              context,
              label: 'Ev / Daire Adı',
              hintText: 'Örn: Evim, Yazlık, Daire 4',
              prefixIcon: Icons.home_outlined,
            ),
          ),
          if (canActForCustomer) ...[
            const SizedBox(height: 8),
            SwitchListTile(
              key: const Key('switch_claim_for_customer'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              value: _forCustomer,
              onChanged: (_isLoading || _otpSent || mustActForCustomer) ? null : (v) => setState(() => _forCustomer = v),
              title: Text(
                'Müşteri adına eşleştir',
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: AppTheme.getTextPrimary(context)),
              ),
              subtitle: Text(
                mustActForCustomer
                    ? 'Servis personeli cihazı yalnızca müşteri adına eşleştirebilir; müşteri doğrulama kodunu size söyler.'
                    : 'Cihaz müşterinin hesabına bağlanır; müşteri doğrulama kodunu size söyler.',
                key: const Key('claim_for_customer_hint'),
                style: TextStyle(fontSize: 11.5, color: AppTheme.getTextMuted(context)),
              ),
            ),
            if (_forCustomer) ..._buildCustomerSection(context),
          ],
          if (_pinLock.isActive) ...[
            const SizedBox(height: 10),
            InlineMessage.warning(
              'Cihaz geçici olarak kilitli. ${_humanDuration(Duration(seconds: _pinLock.remainingSeconds))} sonra tekrar deneyin.',
              key: const Key('claim_lock_notice'),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 10),
            InlineMessage.error(_error!, key: const Key('claim_error')),
          ],
          const SizedBox(height: 10),
        ],
      ),
    );
  }

  List<Widget> _buildCustomerSection(BuildContext context) {
    return [
      const SizedBox(height: 6),
      TextFormField(
        key: const Key('field_claim_customer'),
        controller: _customerController,
        readOnly: _otpSent,
        enabled: !_isLoading,
        keyboardType: TextInputType.emailAddress,
        autocorrect: false,
        enableSuggestions: false,
        style: TextStyle(color: AppTheme.getTextPrimary(context)),
        decoration: _inputDecoration(
          context,
          label: 'Müşteri e-posta / telefon',
          hintText: 'musteri@ornek.com veya 0555 123 45 67',
          prefixIcon: Icons.person_outline,
        ),
      ),
      const SizedBox(height: 10),
      if (!_otpSent)
        OutlinedButton.icon(
          key: const Key('btn_claim_send_otp'),
          onPressed: (_otpSending || _isLoading || _resend.isActive) ? null : _sendOtp,
          icon: _otpSending
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.sms_outlined, size: 18),
          label: Text(_resend.isActive
              ? 'Kod gönderilebilir: ${formatCountdown(_resend.remainingSeconds)}'
              : 'Müşteriye Doğrulama Kodu Gönder'),
        )
      else ...[
        TextFormField(
          key: const Key('field_claim_otp'),
          controller: _otpController,
          enabled: !_isLoading,
          keyboardType: TextInputType.number,
          maxLength: 6,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppTheme.getTextPrimary(context),
            fontSize: 20,
            fontWeight: FontWeight.bold,
            letterSpacing: 6,
          ),
          decoration: _inputDecoration(
            context,
            label: 'Müşterinin söylediği kod',
            hintText: '000000',
            prefixIcon: Icons.pin_rounded,
          ),
        ),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TextButton(
              key: const Key('btn_claim_unlock'),
              onPressed: _isLoading ? null : _unlockFields,
              child: const Text('Bilgileri Düzenle', style: TextStyle(fontSize: 12)),
            ),
            TextButton(
              key: const Key('btn_claim_resend_otp'),
              onPressed: (_isLoading || _otpSending || _resend.isActive)
                  ? null
                  : () async {
                      setState(() => _otpSent = false);
                      await _sendOtp();
                    },
              child: Text(
                _resend.isActive ? 'Yeniden gönder (${formatCountdown(_resend.remainingSeconds)})' : 'Kodu Yeniden Gönder',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
        const InlineMessage.info(
          'Doğrulama kodu gönderildi; cihaz kimliği, PIN ve müşteri bilgisi kilitlendi.',
          key: Key('claim_otp_sent'),
        ),
      ],
    ];
  }

  Widget _buildSuccess(_ClaimSuccessView view) {
    final items = <String>[
      ...view.warnings,
      if (view.customerCreated)
        view.inviteSent
            ? 'Müşteri için yeni hesap açıldı ve davet e-postası gönderildi.'
            : 'Müşteri için yeni hesap açıldı; davet e-postası gönderilemedi, müşteriye şifre sıfırlama bağlantısı gönderin.',
      if (view.technicianUntil != null)
        'Kurulum erişiminiz ${formatLocalDateTime(view.technicianUntil!)} tarihine kadar sürer.',
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const InlineMessage.success('Cihaz eşleştirildi.', key: Key('claim_success')),
        if (view.homeName.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('Daire: ${view.homeName}', style: TextStyle(color: AppTheme.getTextPrimary(context), fontSize: 13)),
        ],
        for (var i = 0; i < items.length; i++) ...[
          const SizedBox(height: 8),
          InlineMessage.warning(items[i], key: Key('claim_warning_$i')),
        ],
      ],
    );
  }

  InputDecoration _inputDecoration(
    BuildContext context, {
    required String label,
    required String hintText,
    required IconData prefixIcon,
    Widget? suffixIcon,
  }) {
    final muted = AppTheme.getTextMuted(context);
    return InputDecoration(
      labelText: label,
      hintText: hintText,
      counterText: '',
      labelStyle: TextStyle(color: muted, fontSize: 13),
      hintStyle: TextStyle(color: muted, fontSize: 13),
      prefixIcon: Icon(prefixIcon, color: muted, size: 20),
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: AppTheme.getCardColor(context),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: AppTheme.getCardBorder(context)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: AppTheme.getCardBorder(context)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppTheme.primaryBlue, width: 1.8),
      ),
    );
  }
}

/// Başarı ekranı verisi (kısmi başarı uyarıları dahil).
class _ClaimSuccessView {
  const _ClaimSuccessView({
    required this.homeName,
    required this.warnings,
    required this.customerCreated,
    required this.inviteSent,
    this.technicianUntil,
  });

  final String homeName;
  final List<String> warnings;
  final bool customerCreated;
  final bool inviteSent;
  final DateTime? technicianUntil;
}

/// Yazılan harfleri büyük harfe çevirir (imleç konumu korunur).
class _UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final upper = newValue.text.toUpperCase();
    if (upper == newValue.text) return newValue;
    return newValue.copyWith(text: upper);
  }
}
