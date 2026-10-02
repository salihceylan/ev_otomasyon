import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../services/automation_state.dart';
import '../../../utils/friendly_error.dart';
import '../../common/auth_form.dart';
import '../../common/cooldown.dart';
import '../../common/date_format.dart';
import '../../common/inline_message.dart';
import '../../common/validators.dart';
import '../../theme/app_theme.dart';

/// Kayıt ekranı. Parola politikası (en az 10 karakter, kırpılmaz), geçerli e-posta, isteğe bağlı
/// telefon (doğrulanır ve ayırıcılardan arındırılarak gönderilir). Hatalar `friendlyError` ile gösterilir.
class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _formKey = GlobalKey<FormState>();
  final _fullNameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  late final Cooldown _cooldown;

  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  bool _isLoading = false;
  String? _error;
  AutovalidateMode _autovalidate = AutovalidateMode.disabled;

  @override
  void initState() {
    super.initState();
    _cooldown = Cooldown(context.read<AutomationState>().clock, () {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _cooldown.dispose();
    _fullNameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _handleRegister() async {
    if (_isLoading || _cooldown.isActive) return;
    setState(() => _autovalidate = AutovalidateMode.onUserInteraction);
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final state = context.read<AutomationState>();
      final phone = AuthValidators.normalizePhone(_phoneController.text);
      final success = await state.register(
        fullName: _fullNameController.text.trim(),
        email: _emailController.text.trim(),
        password: _passwordController.text, // KIRPILMAZ
        phone: phone,
      );
      if (!mounted) return;
      if (success) {
        // Oturum açıldı; AuthGate paneli gösterir. Kayıt sayfasını yığından kaldır.
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e, fallback: 'Kayıt tamamlanamadı. Lütfen tekrar deneyin.'));
      if (e is ApiException && e.isRateLimited) {
        final wait = e.retryAfter ?? e.resendAfter;
        if (wait != null) _cooldown.start(wait);
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = AppTheme.getTextPrimary(context);
    final muted = AppTheme.getTextMuted(context);
    final cooling = _cooldown.isActive;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Kayıt Ol'),
        backgroundColor: Colors.transparent,
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: AutofillGroup(
                child: Form(
                  key: _formKey,
                  autovalidateMode: _autovalidate,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: AppTheme.primaryBlue.withValues(alpha: 0.12),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.person_add_alt_1_rounded, color: AppTheme.primaryBlueLight, size: 44),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'Yeni Hesap Oluşturun',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: primary),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Evinizi ve tüm cihazlarınızı güvenle yönetin',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 14, color: muted),
                      ),
                      const SizedBox(height: 28),
                      TextFormField(
                        key: const Key('field_full_name'),
                        controller: _fullNameController,
                        enabled: !_isLoading,
                        textCapitalization: TextCapitalization.words,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.name],
                        maxLength: 100,
                        style: TextStyle(color: primary),
                        decoration: authInputDecoration(context, label: 'Ad Soyad', prefixIcon: Icons.person_outline)
                            .copyWith(counterText: ''),
                        validator: (val) {
                          if (val == null || val.trim().isEmpty) return 'Lütfen adınızı ve soyadınızı girin';
                          if (val.trim().length < 2) return 'Ad soyad en az 2 karakter olmalıdır';
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        key: const Key('field_email'),
                        controller: _emailController,
                        enabled: !_isLoading,
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.email],
                        autocorrect: false,
                        enableSuggestions: false,
                        style: TextStyle(color: primary),
                        decoration: authInputDecoration(context, label: 'E-Posta Adresi', prefixIcon: Icons.email_outlined),
                        validator: AuthValidators.emailError,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        key: const Key('field_phone'),
                        controller: _phoneController,
                        enabled: !_isLoading,
                        keyboardType: TextInputType.phone,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.telephoneNumber],
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'[0-9+\-\s().]')),
                          LengthLimitingTextInputFormatter(20),
                        ],
                        style: TextStyle(color: primary),
                        decoration: authInputDecoration(
                          context,
                          label: 'Telefon Numarası (İsteğe Bağlı)',
                          prefixIcon: Icons.phone_outlined,
                          hint: '0555 123 45 67',
                        ),
                        validator: (v) => AuthValidators.phoneError(v),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        key: const Key('field_password'),
                        controller: _passwordController,
                        enabled: !_isLoading,
                        obscureText: _obscurePassword,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.newPassword],
                        autocorrect: false,
                        enableSuggestions: false,
                        style: TextStyle(color: primary),
                        decoration: authInputDecoration(
                          context,
                          label: 'Şifre (En az ${AuthValidators.passwordMinLength} karakter)',
                          prefixIcon: Icons.lock_outline,
                          suffixIcon: passwordVisibilityButton(
                            context: context,
                            obscured: _obscurePassword,
                            onToggle: () => setState(() => _obscurePassword = !_obscurePassword),
                          ),
                        ),
                        validator: AuthValidators.passwordPolicyError,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        key: const Key('field_password_confirm'),
                        controller: _confirmPasswordController,
                        enabled: !_isLoading,
                        obscureText: _obscureConfirmPassword,
                        textInputAction: TextInputAction.done,
                        autocorrect: false,
                        enableSuggestions: false,
                        onFieldSubmitted: (_) => _handleRegister(),
                        style: TextStyle(color: primary),
                        decoration: authInputDecoration(
                          context,
                          label: 'Şifre Tekrar',
                          prefixIcon: Icons.lock_reset,
                          suffixIcon: passwordVisibilityButton(
                            context: context,
                            obscured: _obscureConfirmPassword,
                            onToggle: () => setState(() => _obscureConfirmPassword = !_obscureConfirmPassword),
                          ),
                        ),
                        validator: (val) {
                          if (val == null || val.isEmpty) return 'Lütfen şifrenizi tekrar girin';
                          if (val != _passwordController.text) return 'Şifreler eşleşmiyor';
                          return null;
                        },
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 16),
                        InlineMessage.error(_error!, key: const Key('register_error')),
                      ],
                      const SizedBox(height: 24),
                      ElevatedButton(
                        key: const Key('btn_register_submit'),
                        onPressed: (_isLoading || cooling) ? null : _handleRegister,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primaryBlue,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          elevation: 0,
                        ),
                        child: _isLoading
                            ? buttonSpinner()
                            : Text(
                                cooling
                                    ? 'Tekrar dene (${formatCountdown(_cooldown.remainingSeconds)})'
                                    : 'Kayıt Ol ve Giriş Yap',
                                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                              ),
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        alignment: WrapAlignment.center,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text('Zaten bir hesabınız var mı? ', style: TextStyle(color: muted, fontSize: 14)),
                          InkWell(
                            key: const Key('btn_back_to_login'),
                            onTap: _isLoading ? null : () => Navigator.of(context).pop(),
                            child: const Padding(
                              padding: EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                              child: Text(
                                'Giriş Yapın',
                                style: TextStyle(color: AppTheme.primaryBlueLight, fontWeight: FontWeight.bold, fontSize: 14),
                              ),
                            ),
                          ),
                        ],
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
