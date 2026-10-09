import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../models/capabilities.dart';
import '../../../../models/json_utils.dart';
import '../../../../services/automation_state.dart';
import '../../../../utils/friendly_error.dart';
import '../../../common/app_dialogs.dart';
import '../../../common/arc_spinner.dart';
import '../../../common/validators.dart';
import '../setup_fields.dart';
import '../setup_style.dart';
import '../../../theme/app_theme.dart';
import '../../../theme/tokens.dart';
import '../../../widgets/app_pill.dart';
import '../../../widgets/orb/orb_icon_badge.dart';
import 'service_glass.dart';
import '../setup_widgets.dart';
import 'admin_account.dart';

/// Hesap oluşturma sonucu (diyalog yalnızca **sunucu başarılı yanıt verince** kapanır).
class CreateAccountOutcome {
  const CreateAccountOutcome({
    required this.fullName,
    required this.email,
    required this.withPassword,
    this.inviteSent,
    this.inviteWarning,
  });

  final String fullName;
  final String email;

  /// Parola belirlendi (yalnızca süper yönetici). Değilse hesap `pending_invite` olur.
  final bool withPassword;

  /// Etkinleştirme e-postası gönderildi mi (`null`: sunucu bildirmedi).
  final bool? inviteSent;
  final String? inviteWarning;
}

/// Yeni hesap formu.
///
/// * Servis personeli **parola belirleyemez**: parola alanı hiç gösterilmez, hesap `pending_invite` olur
///   ve etkinleştirme bağlantısı müşterinin e-postasına gider.
/// * Süper yönetici isteğe bağlı geçici parola verebilir (en az 10 karakter; **kırpılmaz**).
/// * E-posta biçimi, telefon ve ad doğrulanır; çift dokunuş korunur ([_busy]); hata diyalogda kalır,
///   diyalog yalnızca API başarısından sonra kapanır.
class CreateAccountDialog extends StatefulWidget {
  const CreateAccountDialog({super.key, required this.actorIsSuper, this.defaultRole = GlobalRole.serviceUser});

  final bool actorIsSuper;
  final GlobalRole defaultRole;

  static Future<CreateAccountOutcome?> show(
    BuildContext context, {
    required bool actorIsSuper,
    GlobalRole defaultRole = GlobalRole.serviceUser,
  }) {
    return showAppDialog<CreateAccountOutcome>(
      context,
      barrierDismissible: false,
      builder: (_) => CreateAccountDialog(actorIsSuper: actorIsSuper, defaultRole: defaultRole),
    );
  }

  @override
  State<CreateAccountDialog> createState() => _CreateAccountDialogState();
}

class _CreateAccountDialogState extends State<CreateAccountDialog> {
  static const Duration _timeout = Duration(seconds: 30);

  final TextEditingController _name = TextEditingController();
  final TextEditingController _email = TextEditingController();
  final TextEditingController _phone = TextEditingController();
  final TextEditingController _notes = TextEditingController();
  final TextEditingController _password = TextEditingController();

  late GlobalRole _role = widget.actorIsSuper ? widget.defaultRole : GlobalRole.user;
  bool _busy = false;
  String? _nameError;
  String? _emailError;
  String? _phoneError;
  String? _passwordError;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _phone.dispose();
    _notes.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final name = _name.text.trim();
    final email = _email.text.trim();
    final phone = _phone.text.trim();
    // Parola ASLA kırpılmaz: baştaki/sondaki boşluk parolanın parçasıdır.
    final password = widget.actorIsSuper ? _password.text : '';

    final nameError = name.length < 2 ? 'Ad soyad en az 2 karakter olmalıdır.' : null;
    final emailError = AuthValidators.emailError(email);
    final phoneError = AuthValidators.trMobileError(phone); // karar 11: +90 sonrası 10 hane
    final passwordError = password.isEmpty ? null : AuthValidators.passwordPolicyError(password);
    if (nameError != null || emailError != null || phoneError != null || passwordError != null) {
      setState(() {
        _nameError = nameError;
        _emailError = emailError;
        _phoneError = phoneError;
        _passwordError = passwordError;
        _error = null;
      });
      return;
    }

    final api = context.read<AutomationState>().cloudApi;
    setState(() {
      _busy = true;
      _nameError = null;
      _emailError = null;
      _phoneError = null;
      _passwordError = null;
      _error = null;
    });
    try {
      final res = await api
          .createAdminUser(
            fullName: name,
            email: email,
            password: password.isEmpty ? null : password,
            phone: phone.isEmpty ? null : AuthValidators.canonicalTrPhone(phone),
            role: _role.wire,
            adminNotes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
          )
          .timeout(_timeout);
      if (!mounted) return;
      Navigator.of(context).pop(
        CreateAccountOutcome(
          fullName: name,
          email: email,
          withPassword: password.isNotEmpty,
          inviteSent: asBool(res['invite_sent']),
          inviteWarning: asNonEmptyString(res['invite_warning']),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = friendlyError(e, fallback: 'Hesap oluşturulamadı. Bağlantınızı kontrol edip tekrar deneyin.');
      });
    }
  }

  String get _title {
    if (!widget.actorIsSuper) return 'Yeni Müşteri Hesabı';
    return _role == GlobalRole.user ? 'Yeni Müşteri Hesabı' : 'Yeni Servis Sorumlusu / Yönetici';
  }

  @override
  Widget build(BuildContext context) {
    final muted = SetupColors.muted(context);
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        key: const Key('dialog_create_account'),
        title: Row(
          children: [
            OrbIconBadge(icon: Icons.person_add_alt_1_rounded, family: AppFamilies.violet, pending: _busy),
            const SizedBox(width: 12),
            Expanded(child: Text(_title)),
          ],
        ),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.actorIsSuper) ...[
                  Text('Hesap türü', style: TextStyle(fontSize: AppText.caption, color: muted)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    // Çip dokunma hedefi 48 dp'ye genişlediğinden satır arası görünür boşluk zaten ≈ 15 dp: ek aralık YOK.
                    runSpacing: 0,
                    children: [
                      for (final role in const <GlobalRole>[GlobalRole.superUser, GlobalRole.serviceUser, GlobalRole.user])
                        AppChip(
                          key: Key('chip_role_${role.wire}'),
                          label: role == GlobalRole.superUser
                              ? 'Süper yönetici'
                              : (role == GlobalRole.serviceUser ? 'Servis sorumlusu' : 'Müşteri'),
                          selected: _role == role,
                          onTap: _busy ? null : () => setState(() => _role = role),
                        ),
                    ],
                  ),
                ] else
                  const SetupInfoRow(
                    icon: Icons.info_outline_rounded,
                    color: SetupColors.info,
                    text: 'Servis sorumlusu yalnızca müşteri hesabı oluşturabilir. Hesap etkinleştirme bağlantısı '
                        'müşterinin e-postasına gönderilir; parolayı müşteri kendisi belirler.',
                  ),
                SetupTextField(
                  key: const Key('field_account_name'),
                  controller: _name,
                  label: 'Ad soyad',
                  errorText: _nameError,
                  prefixIcon: Icons.person_rounded,
                  textCapitalization: TextCapitalization.words,
                  enabled: !_busy,
                ),
                SetupTextField(
                  key: const Key('field_account_email'),
                  controller: _email,
                  label: 'E-posta',
                  errorText: _emailError,
                  keyboardType: TextInputType.emailAddress,
                  prefixIcon: Icons.email_rounded,
                  enabled: !_busy,
                ),
                SetupTextField(
                  key: const Key('field_account_phone'),
                  controller: _phone,
                  // Niteleyici etikete değil yardımcı metne (dar diyalogda "Telefon (isteğ…" diye kesiliyordu).
                  label: 'Telefon',
                  helperText: 'İsteğe bağlı',
                  errorText: _phoneError,
                  keyboardType: TextInputType.phone,
                  inputFormatters: const [TrPhoneInputFormatter()],
                  prefixText: kTrPhonePrefix,
                  hint: kTrPhoneHint,
                  prefixIcon: Icons.phone_rounded,
                  enabled: !_busy,
                ),
                if (widget.actorIsSuper)
                  SecretField(
                    key: const Key('field_account_password'),
                    controller: _password,
                    label: 'Geçici parola',
                    helperText: 'İsteğe bağlı. Boş bırakırsanız kullanıcıya hesap etkinleştirme e-postası gider '
                        '(önerilir). En az 10 karakter.',
                    errorText: _passwordError,
                    prefixIcon: Icons.key_rounded,
                  ),
                SetupTextField(
                  key: const Key('field_account_notes'),
                  controller: _notes,
                  label: 'Görev / bölge notu',
                  helperText: 'İsteğe bağlı',
                  prefixIcon: Icons.notes_rounded,
                  maxLines: 2,
                  enabled: !_busy,
                ),
                if (_error != null)
                  ServiceCard(
                    key: const Key('account_error'),
                    accent: SetupColors.error,
                    child: SetupInfoRow(icon: Icons.error_outline_rounded, color: SetupColors.error, bold: true, text: _error!),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            key: const Key('btn_account_cancel'),
            style: AppTheme.quietTextButtonStyle(context),
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: const Text('Vazgeç'),
          ),
          ElevatedButton(
            key: const Key('btn_account_save'),
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const ArcSpinner(size: 18, color: Colors.white, strokeWidth: 2.4)
                : const Text('Kaydet'),
          ),
        ],
      ),
    );
  }
}

/// Hesap düzenleme formu.
///
/// * Parola yalnızca süper yönetici tarafından, **başka** bir hesap için değiştirilebilir (kendi parolası
///   profil ekranından). Başka bir **süper yöneticinin** parolası için kendi mevcut parolanız istenir
///   (`current_password`); sunucu `REAUTH_REQUIRED` derse alan açılır ve yeniden istenir.
/// * Servis personeli parola değiştiremez (kartta "bağlantı gönder" vardır).
/// * Parola kırpılmaz; en az 10 karakter.
class EditAccountDialog extends StatefulWidget {
  const EditAccountDialog({
    super.key,
    required this.account,
    required this.actorIsSuper,
    required this.isSelf,
  });

  final AdminAccount account;
  final bool actorIsSuper;
  final bool isSelf;

  static Future<bool?> show(
    BuildContext context, {
    required AdminAccount account,
    required bool actorIsSuper,
    required bool isSelf,
  }) {
    return showAppDialog<bool>(
      context,
      barrierDismissible: false,
      builder: (_) => EditAccountDialog(account: account, actorIsSuper: actorIsSuper, isSelf: isSelf),
    );
  }

  @override
  State<EditAccountDialog> createState() => _EditAccountDialogState();
}

class _EditAccountDialogState extends State<EditAccountDialog> {
  static const Duration _timeout = Duration(seconds: 30);

  late final TextEditingController _name = TextEditingController(text: widget.account.fullName);
  /// Kayıtlı numara alanın gösteriminde ("+90" önekinden sonraki 10 hane); TR değilse olduğu gibi (karar 11).
  late final String _initialPhone = TrPhoneInputFormatter.display(widget.account.phone);
  late final TextEditingController _phone = TextEditingController(text: _initialPhone);
  late final TextEditingController _notes = TextEditingController(text: widget.account.notes);
  final TextEditingController _password = TextEditingController();
  final TextEditingController _current = TextEditingController();

  bool _busy = false;
  bool _reauth = false;
  String? _nameError;
  String? _phoneError;
  String? _passwordError;
  String? _currentError;
  String? _error;

  bool get _canChangePassword => widget.actorIsSuper && !widget.isSelf;

  /// Başka bir süper yöneticinin parolası: kendi parolanızla yeniden doğrulama gerekir.
  bool get _needsCurrent => _canChangePassword && widget.account.isSuper && (_password.text.isNotEmpty || _reauth);

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _notes.dispose();
    _password.dispose();
    _current.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final name = _name.text.trim();
    final phone = _phone.text.trim();
    final password = _canChangePassword ? _password.text : '';
    final current = _current.text;

    final nameError = name.length < 2 ? 'Ad soyad en az 2 karakter olmalıdır.' : null;
    // Dokunulmamış (ör. eski / yabancı) numara kaydı engellemez; değiştirilen numara +90 sonrası 10 hane olmalı.
    final phoneError = phone == _initialPhone.trim() ? null : AuthValidators.trMobileError(phone);
    final passwordError = password.isEmpty ? null : AuthValidators.passwordPolicyError(password);
    final currentError = (_needsCurrent && current.isEmpty)
        ? 'Başka bir süper yöneticinin parolasını değiştirmek için kendi mevcut parolanızı girin.'
        : null;
    if (nameError != null || phoneError != null || passwordError != null || currentError != null) {
      setState(() {
        _nameError = nameError;
        _phoneError = phoneError;
        _passwordError = passwordError;
        _currentError = currentError;
        _error = null;
      });
      return;
    }

    final api = context.read<AutomationState>().cloudApi;
    setState(() {
      _busy = true;
      _nameError = null;
      _phoneError = null;
      _passwordError = null;
      _currentError = null;
      _error = null;
    });
    try {
      await api
          .updateAdminUser(
            widget.account.id,
            fullName: name,
            phone: phone.isEmpty ? '' : (AuthValidators.canonicalTrPhone(phone) ?? widget.account.phone),
            adminNotes: _notes.text.trim(),
            password: password.isEmpty ? null : password,
            currentPassword: (password.isNotEmpty && widget.account.isSuper) ? current : null,
          )
          .timeout(_timeout);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      final reauth = e is ApiException && e.isReauthRequired;
      setState(() {
        _busy = false;
        if (reauth) {
          // Yanlış / eksik mevcut parola: alan açılır, temizlenir, açıklama alanın altında gösterilir.
          _reauth = true;
          _current.clear();
          _currentError = e.message;
        } else {
          _error = friendlyError(e, fallback: 'Hesap güncellenemedi. Bağlantınızı kontrol edip tekrar deneyin.');
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final muted = SetupColors.muted(context);
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        key: const Key('dialog_edit_account'),
        title: Row(
          children: [
            OrbIconBadge(icon: Icons.edit_rounded, family: AppFamilies.sky, pending: _busy),
            const SizedBox(width: 12),
            Expanded(child: Text('${widget.account.fullName} - Düzenle')),
          ],
        ),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.account.email, style: TextStyle(fontSize: AppText.caption, color: muted)),
                SetupTextField(
                  key: const Key('field_edit_name'),
                  controller: _name,
                  label: 'Ad soyad',
                  errorText: _nameError,
                  prefixIcon: Icons.person_rounded,
                  textCapitalization: TextCapitalization.words,
                  enabled: !_busy,
                ),
                SetupTextField(
                  key: const Key('field_edit_phone'),
                  controller: _phone,
                  label: 'Telefon',
                  errorText: _phoneError,
                  keyboardType: TextInputType.phone,
                  inputFormatters: const [TrPhoneInputFormatter()],
                  prefixText: kTrPhonePrefix,
                  hint: kTrPhoneHint,
                  prefixIcon: Icons.phone_rounded,
                  enabled: !_busy,
                ),
                SetupTextField(
                  key: const Key('field_edit_notes'),
                  controller: _notes,
                  label: 'Görev / bölge notu',
                  prefixIcon: Icons.notes_rounded,
                  maxLines: 2,
                  enabled: !_busy,
                ),
                if (_canChangePassword) ...[
                  SecretField(
                    key: const Key('field_edit_password'),
                    controller: _password,
                    label: 'Yeni parola',
                    helperText: 'Değiştirmeyecekseniz boş bırakın. En az 10 karakter. Kullanıcı ilk girişte parolasını '
                        'değiştirmek zorunda kalır.',
                    errorText: _passwordError,
                    prefixIcon: Icons.key_rounded,
                    onChanged: (_) => setState(() {}),
                  ),
                  if (_needsCurrent)
                    SecretField(
                      key: const Key('field_edit_current_password'),
                      controller: _current,
                      label: 'Kendi mevcut parolanız',
                      helperText: 'Başka bir süper yöneticinin parolasını değiştirmek için kimliğinizi doğrulayın.',
                      errorText: _currentError,
                      prefixIcon: Icons.verified_user_rounded,
                    ),
                ] else if (widget.isSelf)
                  const SetupInfoRow(
                    icon: Icons.info_outline_rounded,
                    color: SetupColors.info,
                    text: 'Kendi parolanızı profil ekranındaki "Şifre değiştir" bölümünden değiştirin.',
                  )
                else if (!widget.actorIsSuper)
                  const SetupInfoRow(
                    icon: Icons.info_outline_rounded,
                    color: SetupColors.info,
                    text: 'Parola değiştirilemez; kullanıcıya kart üzerinden "Bağlantı gönder" ile sıfırlama bağlantısı '
                        'gönderin.',
                  ),
                if (_error != null)
                  ServiceCard(
                    key: const Key('account_error'),
                    accent: SetupColors.error,
                    child: SetupInfoRow(icon: Icons.error_outline_rounded, color: SetupColors.error, bold: true, text: _error!),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            key: const Key('btn_account_cancel'),
            style: AppTheme.quietTextButtonStyle(context),
            onPressed: _busy ? null : () => Navigator.of(context).pop(false),
            child: const Text('Vazgeç'),
          ),
          ElevatedButton(
            key: const Key('btn_account_save'),
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const ArcSpinner(size: 18, color: Colors.white, strokeWidth: 2.4)
                : const Text('Güncelle'),
          ),
        ],
      ),
    );
  }
}
