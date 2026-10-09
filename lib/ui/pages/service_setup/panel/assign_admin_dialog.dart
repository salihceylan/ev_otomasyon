import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../models/json_utils.dart';
import '../../../../services/automation_state.dart';
import '../../../../utils/friendly_error.dart';
import '../../../common/app_dialogs.dart';
import '../../../common/arc_spinner.dart';
import '../../../common/confirm_dialogs.dart';
import '../../../common/validators.dart';
import '../logic/customer_logic.dart';
import '../setup_fields.dart';
import '../setup_style.dart';
import '../../../theme/app_theme.dart';
import '../../../theme/tokens.dart';
import '../../../widgets/orb/orb_icon_badge.dart';
import '../../../widgets/settings/accent_button.dart';
import 'service_glass.dart';
import '../setup_widgets.dart';
import 'subscriber_models.dart';

/// Home Admin atama sonucu: sunucu mesajı + (varsa) kısmi başarı uyarıları.
class AssignAdminOutcome {
  const AssignAdminOutcome({
    required this.message,
    this.warnings = const <String>[],
    this.partial = false,
    this.accountCreated = false,
    this.inviteSent,
    this.forced = false,
  });

  final String message;
  final List<String> warnings;
  final bool partial;

  /// Yeni yönetici için hesap açıldı (davet e-postası ile etkinleştirilir).
  final bool accountCreated;
  final bool? inviteSent;

  /// Süper yönetici gerekçeli zorla atama yaptı (sahibin onayı alınmadı).
  final bool forced;

  bool get hasWarnings => partial || warnings.isNotEmpty;

  static AssignAdminOutcome fromJson(Map<String, dynamic> json, {bool forced = false}) {
    final message = asNonEmptyString(json['message']) ?? 'Home Admin yetkisi başarıyla verildi.';
    return AssignAdminOutcome(
      message: message,
      warnings: <String>[
        for (final w in asList(json['warnings']) ?? const <dynamic>[])
          if (asNonEmptyString(w) != null) asNonEmptyString(w)!,
      ],
      partial: asBool(json['partial']) ?? false,
      accountCreated: asBool(json['account_created']) ?? false,
      inviteSent: asBool(json['invite_sent']),
      forced: forced,
    );
  }
}

/// Kısmi başarı uyarıları (ör. davet e-postası gönderilemedi, MQTT bağlantıları atılamadı).
class AssignWarningsDialog extends StatelessWidget {
  const AssignWarningsDialog({super.key, required this.outcome});

  final AssignAdminOutcome outcome;

  static Future<void> show(BuildContext context, AssignAdminOutcome outcome) {
    return showAppDialog<void>(context, builder: (_) => AssignWarningsDialog(outcome: outcome));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('assign_warnings'),
      title: Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: SetupColors.readable(context, SetupColors.warn)),
          const SizedBox(width: 8),
          const Expanded(child: Text('Atama tamamlandı, ancak uyarılar var')),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(outcome.message, style: TextStyle(height: 1.4, color: SetupColors.text(context))),
            const SizedBox(height: 8),
            for (var i = 0; i < outcome.warnings.length; i++)
              SetupInfoRow(
                key: Key('assign_warning_$i'),
                icon: Icons.info_outline_rounded,
                color: SetupColors.warn,
                text: outcome.warnings[i],
              ),
          ],
        ),
      ),
      actions: [
        ElevatedButton(
          key: const Key('btn_assign_warnings_close'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Tamam'),
        ),
      ],
    );
  }
}

/// Home Admin atama / devretme: bilgi formu -> **ikinci onay penceresi** ("X'in yetkisi kalkacak, Y
/// atanacak") -> (mevcut sahip varsa) **mevcut sahibe giden onay kodu** -> atama.
///
/// * Onay kodu isteği atanacak kişinin bilgisini taşır (sunucu kodu bu kişiye bağlar).
/// * Mevcut sahibe ulaşılamıyorsa **yalnızca süper yönetici**, gerekçe (en az 15 karakter) ve `ZORLA`
///   yazarak, sahibin onayı olmadan atayabilir.
/// * Diyalog yalnızca API **başarılı** olunca kapanır; gönderim sırasında çift tıklama korunur; hatalar
///   diyalog içinde görünür. Sonuç: [AssignAdminOutcome] (uyarılarla) ya da iptalde `null`.
class AssignAdminDialog extends StatefulWidget {
  const AssignAdminDialog({super.key, required this.subscriber});

  final Subscriber subscriber;

  static Future<AssignAdminOutcome?> show(BuildContext context, Subscriber subscriber) {
    return showAppDialog<AssignAdminOutcome>(
      context,
      barrierDismissible: false,
      builder: (_) => AssignAdminDialog(subscriber: subscriber),
    );
  }

  @override
  State<AssignAdminDialog> createState() => _AssignAdminDialogState();
}

enum _Phase { form, otp }

class _AssignAdminDialogState extends State<AssignAdminDialog> {
  static const Duration _timeout = Duration(seconds: 30);
  static const int _forceReasonMin = 15;

  final TextEditingController _name = TextEditingController();
  final TextEditingController _email = TextEditingController();
  final TextEditingController _phone = TextEditingController();
  final TextEditingController _otp = TextEditingController();
  final TextEditingController _reason = TextEditingController();

  _Phase _phase = _Phase.form;
  bool _busy = false;
  bool _showForce = false;
  String? _nameError;
  String? _contactError;
  String? _reasonError;
  String? _error;
  String? _otpMessage;
  DateTime? _resendAt;
  Timer? _ticker;

  CustomerIdentifier? _emailId;
  CustomerIdentifier? _phoneId;

  Subscriber get _s => widget.subscriber;

  @override
  void initState() {
    super.initState();
    final state = context.read<AutomationState>();
    _ticker = state.clock.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _phase == _Phase.otp) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _name.dispose();
    _email.dispose();
    _phone.dispose();
    _otp.dispose();
    _reason.dispose();
    super.dispose();
  }

  bool _validate() {
    String? nameError;
    String? contactError;
    final name = _name.text.trim();
    if (name.length < 2) {
      nameError = 'Ad soyad en az 2 karakter olmalı.';
    } else if (name.length > 100) {
      nameError = 'Ad soyad en fazla 100 karakter olabilir.';
    }
    final emailText = _email.text.trim();
    final phoneText = _phone.text.trim();
    CustomerIdentifier? email;
    CustomerIdentifier? phone;
    if (emailText.isEmpty && phoneText.isEmpty) {
      contactError = 'E-posta veya telefondan en az birini girin.';
    } else {
      if (emailText.isNotEmpty) {
        email = parseCustomerIdentifier(emailText);
        if (email == null || email.kind != CustomerKind.email) {
          contactError = 'E-posta adresi geçersiz görünüyor (ör. ad@ornek.com).';
        }
      }
      if (contactError == null && phoneText.isNotEmpty) {
        // Karar 11: sabit "+90" önekli alan -> 10 hane (5XX XXX XX XX), kanonik +905XXXXXXXXX gönderilir.
        final canonical = AuthValidators.canonicalTrPhone(phoneText);
        if (canonical == null) {
          contactError = AuthValidators.trMobileError(phoneText) ?? 'Telefon numarası geçersiz.';
        } else {
          phone = CustomerIdentifier(CustomerKind.phone, canonical);
        }
      }
    }
    final owner = _s.owner;
    if (contactError == null && owner != null) {
      String tail(String value) {
        final digits = value.replaceAll(RegExp(r'\D'), '');
        return digits.length > 10 ? digits.substring(digits.length - 10) : digits;
      }

      final sameEmail = email != null && (owner.email ?? '').trim().toLowerCase() == email.value;
      final ownerTail = tail(owner.phone ?? '');
      final samePhone = phone != null && ownerTail.length >= 7 && ownerTail == tail(phone.value);
      if (sameEmail || samePhone) {
        contactError = 'Bu kişi zaten dairenin mevcut yöneticisi.';
      }
    }
    setState(() {
      _nameError = nameError;
      _contactError = contactError;
      _error = null;
      _emailId = email;
      _phoneId = phone;
    });
    return nameError == null && contactError == null;
  }

  Future<void> _next() async {
    if (_busy || !_validate()) return;
    final owner = _s.owner;
    final newName = _name.text.trim();
    final confirmed = await showAppDialog<bool>(
      context,
      builder: (ctx) => AlertDialog(
        title: const Text('Yönetici değişikliğini onaylıyor musunuz?'),
        content: Text(
          owner != null
              ? '${owner.fullName} kişisinin "${_s.homeName}" dairesi üzerindeki yetkisi kalkacak ve '
                  '$newName yeni Home Admin olarak atanacak.\n\n'
                  'Dairenin tam kontrolü (röleler, senaryolar, kullanıcı ekleme) yeni yöneticiye geçer. '
                  'Mevcut yöneticiye onay kodu gönderilecek.'
              : '$newName, "${_s.homeName}" dairesinin Home Admin\'i olarak atanacak. '
                  'Dairenin tam kontrolü (röleler, senaryolar, kullanıcı ekleme) bu kişiye geçer.',
        ),
        actions: [
          TextButton(
            key: const Key('btn_assign_cancel_confirm'),
            style: AppTheme.quietTextButtonStyle(ctx),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Vazgeç'),
          ),
          ElevatedButton(
            key: const Key('btn_assign_confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(owner != null ? 'Evet, Devret' : 'Evet, Ata'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (owner != null) {
      await _requestOtp();
    } else {
      await _submit();
    }
  }

  /// Sunucu hata kodlarına göre kullanıcı dili; sahibe ulaşılamıyorsa süper yönetici için zorla atama açılır.
  String _describe(Object e) {
    var text = friendlyError(e);
    if (e is ApiException) {
      final left = e.remainingAttempts;
      if (left != null && !text.contains('Kalan deneme')) text = '$text Kalan deneme hakkı: $left.';
      if (e.code == 'OWNER_UNREACHABLE' || e.code == 'DELIVERY_FAILED') {
        if (context.read<AutomationState>().isSuperUser) {
          _showForce = true;
        } else {
          text = '$text Süper yöneticiye başvurun.';
        }
      }
    }
    return text;
  }

  Future<void> _requestOtp() async {
    final state = context.read<AutomationState>();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await state.cloudApi
          .requestAssignAdminOtp(
            _s.homeId,
            fullName: _name.text.trim(),
            email: _emailId?.value,
            phone: _phoneId?.value,
          )
          .timeout(_timeout);
      if (!mounted) return;
      if (!res.otpRequired) {
        // Sunucuya göre dairede sahip kalmamış: kod gerekmez.
        setState(() => _busy = false);
        await _submit(skipOtp: true);
        return;
      }
      final hint = res.ownerHint;
      setState(() {
        _busy = false;
        _phase = _Phase.otp;
        _otpMessage = res.challenge.message.isEmpty
            ? 'Mevcut yöneticiye${hint == null ? '' : ' ($hint)'} onay kodu gönderildi.'
            : res.challenge.message;
        _resendAt = state.clock.now().add(res.challenge.resendAfter);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _describe(e);
      });
    }
  }

  Future<void> _submit({bool skipOtp = false}) async {
    if (_busy) return;
    final state = context.read<AutomationState>();
    final owner = _s.owner;
    final needsOtp = owner != null && !skipOtp;
    final code = _otp.text.trim();
    if (needsOtp && code.length != 6) {
      setState(() => _error = 'Mevcut yöneticiye giden 6 haneli kodu yazın.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await state.cloudApi
          .assignHomeAdmin(
            homeId: _s.homeId,
            fullName: _name.text.trim(),
            email: _emailId?.value,
            phone: _phoneId?.value,
            otpCode: needsOtp ? code : null,
          )
          .timeout(_timeout);
      if (!mounted) return;
      Navigator.of(context).pop(AssignAdminOutcome.fromJson(res));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _describe(e);
      });
    }
  }

  /// Süper yönetici: sahibin onayı olmadan, gerekçeyle ve `ZORLA` yazarak atama.
  Future<void> _forceAssign() async {
    if (_busy) return;
    if (!_validate()) return;
    final reason = _reason.text.trim();
    if (reason.length < _forceReasonMin) {
      setState(() => _reasonError = 'Gerekçe en az $_forceReasonMin karakter olmalıdır (şu an ${reason.length}).');
      return;
    }
    setState(() => _reasonError = null);
    final owner = _s.owner;
    final ok = await ConfirmDestructiveDialog.show(
      context,
      title: 'Sahibin onayı olmadan atansın mı?',
      message: '${owner?.fullName ?? 'Mevcut yönetici'} onay vermeden "${_s.homeName}" dairesinin yönetimi '
          '${_name.text.trim()} adlı kişiye devredilecek; önceki tüm erişimler kaldırılır. Bu işlem denetim kaydına '
          'gerekçenizle yazılır ve geri alınamaz.',
      confirmPhrase: 'ZORLA',
      confirmLabel: 'Zorla Ata',
    );
    if (!ok || !mounted) return;
    final state = context.read<AutomationState>();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await state.cloudApi
          .assignHomeAdmin(
            homeId: _s.homeId,
            fullName: _name.text.trim(),
            email: _emailId?.value,
            phone: _phoneId?.value,
            force: true,
            reason: reason,
          )
          .timeout(_timeout);
      if (!mounted) return;
      Navigator.of(context).pop(AssignAdminOutcome.fromJson(res, forced: true));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _describe(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final owner = _s.owner;
    final state = context.read<AutomationState>();
    final isSuper = state.isSuperUser;
    final now = state.clock.now();
    final canResend = _resendAt == null || !now.isBefore(_resendAt!);
    final left = _resendAt == null ? Duration.zero : _resendAt!.difference(now);
    final showForceLink = isSuper && owner != null && !_showForce;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Row(
          children: [
            OrbIconBadge(icon: Icons.assignment_ind_rounded, family: AppFamilies.sky, pending: _busy),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Başlık KESİLMEZ (1.5 yazıda "Home Admin …" diye eylem sözcüğü kayboluyordu): en çok 2 satıra sarar.
                  Text(owner != null ? 'Home Admin Devret' : 'Home Admin Ata', maxLines: 2, overflow: TextOverflow.ellipsis),
                  if (owner != null) ...[
                    const SizedBox(height: 6),
                    ServiceStepDots(
                      current: _phase == _Phase.form ? 1 : 2,
                      total: 2,
                      label: _phase == _Phase.form ? 'Adım 1 / 2: yeni yönetici bilgisi' : 'Adım 2 / 2: onay kodu',
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ServiceCard(
                  margin: EdgeInsets.zero,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_s.homeName, style: const TextStyle(fontWeight: FontWeight.w800)),
                      if (_s.deviceUuid.isNotEmpty)
                        // Kimlik tek satır: tireden bölünüp iki satıra yayılmaz, sığmazsa küçülür.
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: AlignmentDirectional.centerStart,
                          child: Text(
                            'Pano: ${_s.deviceUuid}',
                            maxLines: 1,
                            softWrap: false,
                            style: SetupText.mono(fontSize: AppText.badge, color: SetupColors.muted(context)),
                          ),
                        ),
                      if (owner != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            'Mevcut yönetici: ${owner.fullName} (${owner.contact})',
                            style: TextStyle(fontSize: AppText.caption, color: SetupColors.muted(context)),
                          ),
                        ),
                    ],
                  ),
                ),
                if (_phase == _Phase.form) ...[
                  SetupTextField(
                    key: const Key('field_admin_name'),
                    controller: _name,
                    label: 'Yeni yönetici adı',
                    hint: 'Ad Soyad',
                    prefixIcon: Icons.person_rounded,
                    errorText: _nameError,
                    textInputAction: TextInputAction.next,
                    enabled: !_busy,
                  ),
                  SetupTextField(
                    key: const Key('field_admin_email'),
                    controller: _email,
                    label: 'E-posta adresi',
                    hint: 'ornek@mail.com',
                    prefixIcon: Icons.email_rounded,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    enabled: !_busy,
                  ),
                  SetupTextField(
                    key: const Key('field_admin_phone'),
                    controller: _phone,
                    label: 'Telefon numarası',
                    hint: kTrPhoneHint,
                    prefixText: kTrPhonePrefix,
                    inputFormatters: const [TrPhoneInputFormatter()],
                    prefixIcon: Icons.phone_rounded,
                    keyboardType: TextInputType.phone,
                    errorText: _contactError,
                    helperText: 'E-posta ya da telefondan en az birini girin.',
                    enabled: !_busy,
                  ),
                ] else ...[
                  ServiceCard(
                    accent: SetupColors.ok,
                    child: SetupInfoRow(
                      icon: Icons.mark_email_read_rounded,
                      color: SetupColors.ok,
                      text: _otpMessage ?? 'Mevcut yöneticiye onay kodu gönderildi.',
                    ),
                  ),
                  SetupTextField(
                    key: const Key('field_assign_otp'),
                    controller: _otp,
                    label: '6 haneli onay kodu',
                    helperText: 'Mevcut yöneticinin size söylediği kod',
                    prefixIcon: Icons.password_rounded,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    inputFormatters: [digitsOnly],
                    monospace: true,
                    enabled: !_busy,
                  ),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton(
                      key: const Key('btn_assign_resend'),
                      style: setupInlineActionStyle(),
                      onPressed: (_busy || !canResend) ? null : _requestOtp,
                      child: Text(canResend ? 'Kodu yeniden gönder' : 'Yeniden gönder: ${left.inSeconds + 1} sn sonra'),
                    ),
                  ),
                ],
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      _error!,
                      key: const Key('assign_error'),
                      style: TextStyle(
                        color: SetupColors.readable(context, SetupColors.error),
                        fontSize: AppText.caption,
                        fontWeight: FontWeight.w600,
                        height: 1.3,
                      ),
                    ),
                  ),
                if (showForceLink)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton(
                      key: const Key('btn_assign_force_toggle'),
                      style: setupInlineActionStyle(),
                      onPressed: _busy ? null : () => setState(() => _showForce = true),
                      child: const Text('Sahibe ulaşılamıyor mu? (süper yönetici)'),
                    ),
                  ),
                if (_showForce && isSuper && owner != null)
                  ServiceCard(
                    key: const Key('assign_force_card'),
                    accent: SetupColors.error,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SetupInfoRow(
                          icon: Icons.warning_amber_rounded,
                          color: SetupColors.error,
                          bold: true,
                          text: 'Zorla atama: mevcut yöneticinin onayı alınmaz. Yalnızca sahibe ulaşılamıyorsa kullanın.',
                        ),
                        SetupTextField(
                          key: const Key('field_force_reason'),
                          controller: _reason,
                          label: 'Gerekçe',
                          helperText: 'En az $_forceReasonMin karakter',
                          errorText: _reasonError,
                          maxLines: 2,
                          enabled: !_busy,
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton(
                          key: const Key('btn_assign_force'),
                          onPressed: _busy ? null : _forceAssign,
                          // Çerçeve + metin AYNI aileden ve AA okunur (ham kırmızı koyu temada ≈ 3.8:1'di).
                          style: accentOutlinedButtonStyle(context, AppFamilies.rose),
                          child: const Text('Gerekçeyle Zorla Ata', textAlign: TextAlign.center),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            key: const Key('btn_assign_cancel'),
            style: AppTheme.quietTextButtonStyle(context),
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: const Text('İptal'),
          ),
          ElevatedButton(
            key: _phase == _Phase.form ? const Key('btn_assign_next') : const Key('btn_assign_submit'),
            onPressed: _busy ? null : (_phase == _Phase.form ? _next : _submit),
            child: _busy
                ? const ArcSpinner(size: 18, color: Colors.white, strokeWidth: 2.4)
                : Text(_phase == _Phase.form ? 'Devam' : 'Devret'),
          ),
        ],
      ),
    );
  }
}
