import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../services/automation_state.dart';
import '../../../utils/friendly_error.dart';
import '../../common/auth_form.dart';
import '../../common/confirm_dialogs.dart';
import '../../common/inline_message.dart';
import '../../common/validators.dart';
import '../../theme/app_theme.dart';

/// Parola değiştirme ekranı.
///
/// * [forced] `true` (sunucu `must_change_password` dedi; ör. teknisyenin açtığı müşteri hesabı ilk
///   giriş): geri dönülemez, yalnızca parola değiştirilir ya da **çıkış** yapılır. `AuthGate` bu
///   durumda panoyu açmaz; parola değişince bayrak kalkar ve pano otomatik açılır.
/// * Gönüllü kullanımda (profil menüsünden) başarıda sayfa kapanır.
///
/// Parolalar **kırpılmaz**. Sunucu diğer tüm cihazların oturumlarını kapatır ve bu cihaza yeni
/// belirteçler verir (durum katmanı yazar).
class ChangePasswordPage extends StatefulWidget {
  const ChangePasswordPage({super.key, this.forced = false});

  final bool forced;

  @override
  State<ChangePasswordPage> createState() => _ChangePasswordPageState();
}

class _ChangePasswordPageState extends State<ChangePasswordPage> {
  final _formKey = GlobalKey<FormState>();
  final _currentController = TextEditingController();
  final _newController = TextEditingController();
  final _confirmController = TextEditingController();

  bool _obscure = true;
  bool _busy = false;
  String? _error;
  String? _currentFieldError;
  AutovalidateMode _autovalidate = AutovalidateMode.disabled;

  @override
  void dispose() {
    _currentController.dispose();
    _newController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _autovalidate = AutovalidateMode.onUserInteraction;
      _currentFieldError = null;
    });
    if (!_formKey.currentState!.validate()) return;
    final state = context.read<AutomationState>();
    final messenger = ScaffoldMessenger.maybeOf(context);
    final navigator = Navigator.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await state.changePassword(
        currentPassword: _currentController.text,
        newPassword: _newController.text,
      );
      if (!mounted) return;
      messenger?.showSnackBar(
        const SnackBar(
          content: Text('Şifreniz değiştirildi. Diğer cihazlardaki oturumlar kapatıldı.'),
          backgroundColor: AppTheme.accentGreen,
          behavior: SnackBarBehavior.floating,
        ),
      );
      if (!widget.forced) navigator.pop(true);
      // forced: bayrak kalktı; AuthGate panoyu kendisi gösterir.
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        if (e is ApiException && e.isInvalidCredentials) {
          _currentFieldError = 'Mevcut şifre hatalı.';
        } else {
          _error = friendlyError(e, fallback: 'Şifre değiştirilemedi. Lütfen tekrar deneyin.');
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AutomationState>();
    final primary = AppTheme.getTextPrimary(context);
    final muted = AppTheme.getTextMuted(context);

    return PopScope(
      canPop: !widget.forced && !_busy,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.forced ? 'Şifrenizi Değiştirin' : 'Şifre Değiştir'),
          automaticallyImplyLeading: !widget.forced && !_busy,
          actions: [
            if (widget.forced)
              TextButton.icon(
                key: const Key('btn_forced_logout'),
                onPressed: _busy ? null : () => confirmAndLogout(context, state),
                icon: const Icon(Icons.logout_rounded, size: 18),
                label: const Text('Çıkış'),
              ),
          ],
        ),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Form(
                  key: _formKey,
                  autovalidateMode: _autovalidate,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Icon(widget.forced ? Icons.password_rounded : Icons.lock_reset_rounded,
                          size: 56, color: AppTheme.primaryBlueLight),
                      const SizedBox(height: 16),
                      if (widget.forced)
                        const InlineMessage.warning(
                          'Güvenliğiniz için devam etmeden önce size verilen geçici şifreyi değiştirmeniz gerekiyor.',
                          key: Key('forced_notice'),
                        )
                      else
                        Text(
                          'Şifrenizi değiştirdiğinizde diğer tüm cihazlardaki oturumlarınız kapatılır.',
                          style: TextStyle(color: muted, fontSize: 13, height: 1.4),
                        ),
                      const SizedBox(height: 20),
                      TextFormField(
                        key: const Key('field_current_password'),
                        controller: _currentController,
                        enabled: !_busy,
                        obscureText: _obscure,
                        autocorrect: false,
                        enableSuggestions: false,
                        autofillHints: const [AutofillHints.password],
                        style: TextStyle(color: primary),
                        decoration: authInputDecoration(
                          context,
                          label: widget.forced ? 'Geçici / Mevcut Şifre' : 'Mevcut Şifre',
                          prefixIcon: Icons.lock_outline,
                        ).copyWith(errorText: _currentFieldError),
                        validator: (v) => (v == null || v.isEmpty) ? 'Lütfen mevcut şifrenizi girin' : null,
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        key: const Key('field_new_password'),
                        controller: _newController,
                        enabled: !_busy,
                        obscureText: _obscure,
                        autocorrect: false,
                        enableSuggestions: false,
                        autofillHints: const [AutofillHints.newPassword],
                        style: TextStyle(color: primary),
                        decoration: authInputDecoration(
                          context,
                          label: 'Yeni Şifre (En az ${AuthValidators.passwordMinLength} karakter)',
                          prefixIcon: Icons.lock_reset,
                          suffixIcon: passwordVisibilityButton(
                            context: context,
                            obscured: _obscure,
                            onToggle: () => setState(() => _obscure = !_obscure),
                          ),
                        ),
                        validator: (v) {
                          final policy = AuthValidators.passwordPolicyError(v, emptyMessage: 'Lütfen yeni şifrenizi girin');
                          if (policy != null) return policy;
                          if (v == _currentController.text) return 'Yeni şifre mevcut şifreyle aynı olamaz';
                          return null;
                        },
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        key: const Key('field_confirm_password'),
                        controller: _confirmController,
                        enabled: !_busy,
                        obscureText: _obscure,
                        autocorrect: false,
                        enableSuggestions: false,
                        style: TextStyle(color: primary),
                        decoration: authInputDecoration(context, label: 'Yeni Şifre Tekrar', prefixIcon: Icons.lock_clock_outlined),
                        validator: (v) {
                          if (v == null || v.isEmpty) return 'Lütfen yeni şifrenizi tekrar girin';
                          if (v != _newController.text) return 'Şifreler eşleşmiyor';
                          return null;
                        },
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 14),
                        InlineMessage.error(_error!, key: const Key('change_password_error')),
                      ],
                      const SizedBox(height: 22),
                      ElevatedButton(
                        key: const Key('btn_change_password'),
                        onPressed: _busy ? null : _submit,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primaryBlue,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 15),
                        ),
                        child: _busy ? buttonSpinner() : const Text('Şifreyi Değiştir', style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
