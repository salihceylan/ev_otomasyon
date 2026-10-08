import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../models/capabilities.dart';
import '../../../models/json_utils.dart';
import '../../../services/automation_state.dart';
import '../../../utils/friendly_error.dart';
import '../../../utils/qr_claim_parser.dart';
import '../../common/app_dialogs.dart';
import '../../common/cooldown.dart';
import '../../common/date_format.dart';
import '../../common/inline_message.dart';
import '../../common/validators.dart';
import '../../theme/app_theme.dart';
import '../../widgets/settings/accent_button.dart';
import '../../theme/tokens.dart';
import '../../widgets/orb/orb.dart';
import '../wifi_recovery_dialog.dart';

String _humanDuration(Duration d) {
  final seconds = d.inSeconds;
  if (seconds >= 120) return '${(seconds / 60).ceil()} dakika';
  return '$seconds saniye';
}

/// Diyaloğun durumdan okuduğu yetkiler (PF-06: `context.select`; `Capabilities` yerine skalerler).
typedef _ClaimPerms = ({bool canClaim, bool isStaff, bool isSuperUser, bool mustActForCustomer});

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
    // Yanlış kurulum PIN'i sunucuda 403 FORBIDDEN olarak gelir; genel "yetkiniz yok" metninden ÖNCE ayrılır.
    if (error.isWrongSetupPin) return _withRemaining(error);
    if (error.isForbidden) {
      return 'Bu işlem için yetkiniz yok veya bu cihazı eşleştiremezsiniz.';
    }
    if (error.isInvalidCredentials || error.isValidation || error.remainingAttempts != null) {
      return _withRemaining(error);
    }
    if (error.isNetwork) {
      return 'Sunucuya ulaşılamadı. İnternet bağlantınızı kontrol edip tekrar deneyin.';
    }
    return error.message;
  }
  return friendlyError(error, fallback: 'Eşleştirme tamamlanamadı. Lütfen tekrar deneyin.');
}

/// Eşleştirme sonrası bilgi: pano (v1.3.0+) buluta kendiliğinden bağlanır (CONTRACTS §3f bootstrap). Eski yazılımlı pano
/// bunu yapamaz (bireysel-1); Wi-Fi kurulumunun yeri doğru düğmeyle söylenir (bireysel-11).
const String claimCloudBootstrapNote =
    'Pano yazılımı v1.3.0 ve üstüyse pano internete bağlı olduğunda birkaç dakika içinde kendiliğinden buluta bağlanır. '
    'Pano henüz ev ağına bağlı değilse Ayarlar > Wi-Fi Şifre Değişimi & Kurtarma (girişsiz: giriş ekranındaki Pano Wi-Fi '
    'Kurulumu) ile bağlayın.';

/// Art arda ikinci PIN kilidinde gösterilen yönlendirme (bireysel-7).
const String claimRepeatedLockHint =
    'Başka bir hesaptan hatalı denemeler olabilir; etiket sizdeyse satıcınıza/yetkili servise başvurun.';

/// Wi-Fi sihirbazında hazırlanmamış görülen pano için eşleme öncesi uyarı (bireysel-13).
const String claimUnprovisionedWarning =
    'Bu pano ilk hazırlığı (provizyon) görmemiş; sahiplenseniz de bu haliyle buluta bağlanamaz. Satıcınıza / yetkili '
    'servise başvurun; ev sahibiyseniz servise Yetkili Servis İçin Geçici PIN verebilirsiniz.';

/// Sunucu mesajı + kalan deneme (mesaj sayıyı zaten içeriyorsa tekrarlanmaz).
String _withRemaining(ApiException error) {
  final remaining = error.remainingAttempts;
  if (remaining == null || error.message.toLowerCase().contains('kalan deneme')) return error.message;
  return '${error.message} Kalan deneme: $remaining.';
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
    return showAppDialog<bool>(
      context,
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

  /// Art arda alınan PIN kilidi (423) sayısı (bireysel-7); başka bir sonuçta sıfırlanır.
  int _pinLockStreak = 0;

  @override
  void initState() {
    super.initState();
    final state = context.read<AutomationState>();
    _uidController = TextEditingController(text: widget.initialUid ?? '');
    _pinController = TextEditingController(text: widget.initialPin ?? '');
    _homeNameController = TextEditingController(text: 'Evim');
    // PF-23: tikler diyaloğu kurmaz; geri sayım metinleri `remaining` ile yalnız küçük builder'larda güncellenir,
    // düğme kilidi başlangıç/bitişte `_refresh` ile yeniden kurulur.
    _resend = Cooldown(state.clock, _refresh, notifyOnTick: false);
    _pinLock = Cooldown(state.clock, _refresh, notifyOnTick: false);
    // Kalıcı servis personeli (küresel `service_user`) kendi adına cihaz sahiplenemez (sunucu 400
    // reddeder): müşteri adına eşleme baştan açık ve kapatılamaz.
    _forCustomer = _mustActForCustomer(state);
  }

  static bool _mustActForCustomer(AutomationState state) =>
      GlobalRole.parse(state.currentUser?.role) == GlobalRole.serviceUser;

  static _ClaimPerms _permsOf(AutomationState state) {
    final caps = state.capabilities;
    return (
      canClaim: caps.canClaimDevice,
      isStaff: caps.isStaff,
      isSuperUser: caps.isSuperUser,
      mustActForCustomer: _mustActForCustomer(state),
    );
  }

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
      _pinLockStreak = 0;
      final account = res.customerAccount;
      // Müşteri hesabı zaten vardı ama etkinleştirilmemiş (uyelik-1): bilgi kapanmadan gösterilir.
      final pending = account != null && !account.created && account.status == 'pending_invite';
      final hasExtra = res.warnings.isNotEmpty || (account?.created ?? false) || pending;
      if (!hasExtra) {
        // Servis rolü olmayan kullanıcıya panoyu ev ağına bağlamanın yolu (bireysel-11): diyalog kapandıktan sonra da
        // açılabilsin diye kök gezginin bağlamı tutulur.
        final perms = _permsOf(state);
        final serviceRole = perms.isStaff || perms.isSuperUser;
        final navContext = Navigator.of(context, rootNavigator: true).context;
        final deviceUuid = res.deviceUuid.isNotEmpty ? res.deviceUuid : uid;
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: const Text('Cihaz başarıyla evinize eşleştirildi.'),
            // Beyaz yazılı dolgu tonu (ham yeşil zeminde beyaz metin ≈2.5:1 idi).
            backgroundColor: AppTheme.filledAccent(AppTheme.accentGreen),
            behavior: SnackBarBehavior.floating,
            action: serviceRole
                ? null
                : SnackBarAction(
                    label: 'Wi-Fi Kurulumu',
                    textColor: Colors.white,
                    onPressed: () {
                      if (navContext.mounted) unawaited(WifiRecoveryDialog.show(navContext, deviceUuid: deviceUuid));
                    },
                  ),
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
          customerCreated: account?.created ?? false,
          customerPending: pending,
          securityReset: account?.securityReset ?? false,
          inviteSent: account?.inviteSent ?? false,
          technicianUntil: res.technicianAccessExpiresAt,
        );
      });
    } catch (e) {
      if (!mounted) return;
      // Aynı sahibin yeniden sahiplenmesi (yanıtı kaybolan önceki deneme; bireysel-3): başarı sayılır.
      if (e is ApiException && e.statusCode == 409 && e.reason == 'ALREADY_YOURS') {
        await _adoptAlreadyYours(state, e);
        return;
      }
      var message = claimErrorMessage(e);
      if (e is ApiException && e.isPinLocked) {
        _pinLockStreak++;
        if (_pinLockStreak >= 2) message = '$message $claimRepeatedLockHint';
      } else {
        _pinLockStreak = 0;
      }
      if (e is ApiException && e.isNetwork) {
        // İstek sunucuda tamamlanmış olabilir (yanıt kayboldu): ev listesi arka planda yenilenir (bireysel-3).
        unawaited(state.fetchHomes(autoSelect: false));
        message = '$message İşlem sunucuda tamamlanmış olabilir; ev listeniz yenileniyor.';
      }
      setState(() {
        _isLoading = false;
        _error = message;
      });
      if (e is ApiException && (e.isPinLocked || e.isRateLimited)) {
        final wait = e.retryAfter ?? e.resendAfter;
        if (wait != null) _pinLock.start(wait);
      }
    }
  }

  /// `409 CONFLICT reason:ALREADY_YOURS` (data: {home_id, home_name}): cihaz zaten bu hesabın evinde. Ev listesi yenilenir,
  /// (müşteri kullanıcısında) o ev seçilir ve diyalog başarıyla kapanır (bireysel-3).
  Future<void> _adoptAlreadyYours(AutomationState state, ApiException e) async {
    final data = asMap(e.details?['data']);
    final homeId = asNonEmptyString(data?['home_id']);
    final perms = _permsOf(state);
    final staff = perms.isStaff || perms.isSuperUser;
    try {
      await state.fetchHomes(autoSelect: false);
      final home = homeId == null ? null : state.homeById(homeId);
      if (!staff && home != null) await state.selectHome(home);
    } catch (_) {
      // Liste yenilenemese de cihazın evde olduğu bilinir.
    }
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(staff ? 'Cihaz zaten müşterinin evine bağlı.' : 'Cihaz zaten evinizde.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
    Navigator.of(context).pop(true);
  }

  // ---------------------------------------------------------------------------
  // Arayüz
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // PF-06: yalnız bu diyaloğun okuduğu yetkiler izlenir; ilgisiz bildirim diyaloğu yeniden kurmaz.
    final perms = context.select<AutomationState, _ClaimPerms>(_permsOf);

    return PopScope(
      canPop: !_isLoading,
      // Yüzey ve şekil temanın diyalog stilinden gelir (yerel zemin/şekil override'ı yok).
      child: AlertDialog(
        title: Row(
          children: [
            OrbIconBadge(
              icon: _success != null ? Icons.check_rounded : Icons.qr_code_2_rounded,
              family: _success != null ? AppFamilies.emerald : AppFamilies.sky,
              active: true,
              pending: _isLoading,
            ),
            const SizedBox(width: 12),
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
            child: !perms.canClaim
                ? const InlineMessage.error('Bu hesapla cihaz eşleştiremezsiniz.', key: Key('claim_forbidden'))
                : (_success != null ? _buildSuccess(_success!) : _buildForm(context, perms)),
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        actions: _success != null || !perms.canClaim
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
                  style: accentButtonStyle(null),
                  child: _isLoading
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : ValueListenableBuilder<int>(
                          valueListenable: _pinLock.remaining,
                          builder: (context, seconds, _) => Text(
                            seconds > 0 ? 'Bekleyin (${formatCountdown(seconds)})' : 'Eşle & Sahiplen',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                ),
              ],
      ),
    );
  }

  Widget _buildForm(BuildContext context, _ClaimPerms perms) {
    final canActForCustomer = perms.isStaff || perms.isSuperUser;
    final mustActForCustomer = perms.mustActForCustomer;
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
          if (_knownUnprovisioned(context)) ...[
            const InlineMessage.warning(claimUnprovisionedWarning, key: Key('claim_unprovisioned_warning')),
            const SizedBox(height: 12),
          ],
          TextFormField(
            key: const Key('field_claim_uid'),
            controller: _uidController,
            onChanged: (_) => setState(() {}), // hazırlanmamış pano uyarısı kimliğe göre (bireysel-13)
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
                style: TextStyle(fontSize: 12, color: AppTheme.getTextMuted(context)),
              ),
            ),
            if (_forCustomer) ..._buildCustomerSection(context),
          ],
          if (_pinLock.isActive) ...[
            const SizedBox(height: 10),
            ValueListenableBuilder<int>(
              valueListenable: _pinLock.remaining,
              builder: (context, seconds, _) => InlineMessage.warning(
                'Cihaz geçici olarak kilitli. ${_humanDuration(Duration(seconds: seconds))} sonra tekrar deneyin.',
                key: const Key('claim_lock_notice'),
              ),
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
          label: ValueListenableBuilder<int>(
            valueListenable: _resend.remaining,
            builder: (context, seconds, _) =>
                Text(seconds > 0 ? 'Kod gönderilebilir: ${formatCountdown(seconds)}' : 'Müşteriye Doğrulama Kodu Gönder'),
          ),
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
              child: ValueListenableBuilder<int>(
                valueListenable: _resend.remaining,
                builder: (context, seconds, _) => Text(
                  seconds > 0 ? 'Yeniden gönder (${formatCountdown(seconds)})' : 'Kodu Yeniden Gönder',
                  style: const TextStyle(fontSize: 12),
                ),
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

  /// Bu kimlik Wi-Fi sihirbazında hazırlanmamış (`provisioned:false`) görüldü mü (bireysel-13).
  bool _knownUnprovisioned(BuildContext context) {
    final uid = QrClaimParser.normalizeUid(_uidController.text);
    return uid != null && context.read<AutomationState>().isKnownUnprovisioned(uid);
  }

  Widget _buildSuccess(_ClaimSuccessView view) {
    final items = <String>[
      ...view.warnings,
      if (view.customerCreated)
        view.inviteSent
            ? 'Müşteri için yeni hesap açıldı ve davet e-postası gönderildi.'
            : 'Müşteri için yeni hesap açıldı; davet e-postası gönderilemedi, müşteriye şifre sıfırlama bağlantısı gönderin.',
      if (view.customerPending)
        view.inviteSent
            ? 'Müşteri hesabı henüz etkinleştirilmedi; davet yeniden gönderildi.'
            : 'Müşteri hesabı henüz etkinleştirilmedi; davet gönderilemedi; müşteri Şifremi unuttum ile etkinleştirebilir.',
      if (view.securityReset && !view.warnings.any((w) => w.contains('güvenlik için sıfırlandı')))
        'Müşterinin doğrulanmamış mevcut hesabı güvenlik için sıfırlandı; şifre belirleme e-postası gönderildi.',
      if (view.technicianUntil != null)
        'Kurulum erişiminiz ${formatLocalDateTime(view.technicianUntil!)} tarihine kadar sürer.',
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(
          child: OrbIconBadge(
            key: Key('claim_success_orb'),
            icon: Icons.check_rounded,
            family: AppFamilies.emerald,
            size: OrbSize.lg,
            active: true,
            status: OrbStatus.success,
          ),
        ),
        const SizedBox(height: 12),
        const InlineMessage.success('Cihaz eşleştirildi.', key: Key('claim_success')),
        if (view.homeName.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('Daire: ${view.homeName}', style: TextStyle(color: AppTheme.getTextPrimary(context), fontSize: 13)),
        ],
        for (var i = 0; i < items.length; i++) ...[
          const SizedBox(height: 8),
          InlineMessage.warning(items[i], key: Key('claim_warning_$i')),
        ],
        const SizedBox(height: 8),
        // Pano (v1.3.0+) internete çıkınca bulut kimliğini kendisi alır (CONTRACTS §3f); sürüm denetimi yapılmaz.
        const InlineMessage.info(claimCloudBootstrapNote, key: Key('claim_cloud_note')),
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
      // Alan biçimi (dolgu, köşe, odak halkası) temanın giriş stilinden gelir.
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
    this.customerPending = false,
    this.securityReset = false,
    this.technicianUntil,
  });

  final String homeName;
  final List<String> warnings;
  final bool customerCreated;
  final bool customerPending;
  final bool securityReset;
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
