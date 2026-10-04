import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../services/automation_state.dart';
import '../../../utils/friendly_error.dart';
import '../../common/auth_form.dart';
import '../../common/confirm_dialogs.dart' show authPrimaryLabel;
import '../../common/cooldown.dart';
import '../../common/date_format.dart';
import '../../common/inline_message.dart';
import '../../common/validators.dart';
import '../../motion/motion.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/neon_app_bar.dart';
import '../../widgets/orb/orb.dart';
import '../../widgets/surface_card.dart';

/// Kayıt ekranı. Parola politikası (en az 10 karakter, kırpılmaz), geçerli e-posta, isteğe bağlı
/// telefon (doğrulanır ve ayırıcılardan arındırılarak gönderilir). Hatalar `friendlyError` ile gösterilir.
///
/// Görünüm: başlık, alt başlık, alanlar, düğme ve "Giriş Yapın" bağlantısı TEK cam plakada ([SurfaceCard]) durur:
/// metin arkadaki devre fotoğrafının üstünde kalmaz (açık temada izler alt başlığı ve bağlantıyı kesiyordu).
/// Alan etiketleri kısadır; kurallar yardımcı metindedir ("Şifre" + "En az 10 karakter"): büyük yazıda etiket
/// "…" ile kesilmez.
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
      // Ortak Neon Glass üst çubuk (cam geri diski + 18/700 başlık, 16 dp oluk): çıplak Material `AppBar`ın düz ← glifi
      // ve başlığı doğrudan devre fotoğrafı üzerinde duruyordu; ikincil sayfalarla aynı dil. Sayfa gövdesinde zaten
      // büyük bir orb olduğundan çubukta özellik orb'u YOK. Geri: `Navigator.maybePop` (eski `BackButton` ile aynı).
      appBar: const NeonAppBar(title: 'Kayıt Ol'),
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
                      const Center(
                        child: OrbIconBadge(icon: Icons.person_add_alt_1_rounded, family: AppFamilies.sky, size: OrbSize.xl, glow: true),
                      ),
                      const SizedBox(height: 16),
                      StaggeredEntrance(
                        index: 1,
                        step: const Duration(milliseconds: 70),
                        child: SurfaceCard(
                          padding: const EdgeInsets.fromLTRB(18, 22, 18, 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
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
                              const SizedBox(height: 22),
                              TextFormField(
                                key: const Key('field_full_name'),
                                controller: _fullNameController,
                                enabled: !_isLoading,
                                textCapitalization: TextCapitalization.words,
                                textInputAction: TextInputAction.next,
                                autofillHints: const [AutofillHints.name],
                                maxLength: 100,
                                style: TextStyle(color: primary),
                                decoration: authInputDecoration(
                                  context,
                                  label: 'Ad Soyad',
                                  prefixIcon: Icons.person_outline_rounded,
                                  counterText: '',
                                ),
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
                                // Etiket kısa; "isteğe bağlı" bilgisi yardımcı metinde (etiket kesilmez).
                                decoration: authInputDecoration(
                                  context,
                                  label: 'Telefon',
                                  helper: 'İsteğe bağlı',
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
                                // Kural etikette değil yardımcı metinde: "Şifre (En az 10 …" gibi kesilmez.
                                decoration: authInputDecoration(
                                  context,
                                  label: 'Şifre',
                                  helper: 'En az ${AuthValidators.passwordMinLength} karakter',
                                  prefixIcon: Icons.lock_outline_rounded,
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
                                  prefixIcon: Icons.verified_user_outlined,
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
                              const SizedBox(height: 22),
                              // Birincil düğme: tür ElevatedButton KALIR; gradyan/şekil/gölge temadan gelir.
                              ElevatedButton(
                                key: const Key('btn_register_submit'),
                                onPressed: (_isLoading || cooling) ? null : _handleRegister,
                                child: _isLoading
                                    ? buttonSpinner()
                                    : Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (cooling) ...[CooldownArc(remaining: _cooldown.remaining, color: muted), const SizedBox(width: 10)],
                                          Flexible(
                                            child: DefaultTextStyle.merge(
                                              textAlign: TextAlign.center,
                                              child: authPrimaryLabel(
                                                cooling ? 'Tekrar dene (${formatCountdown(_cooldown.remainingSeconds)})' : 'Kayıt Ol ve Giriş Yap',
                                                // Bekleme: kalan süre TEK bilgi; pasif düğmenin soluk ön planı (≈3.4:1) yerine tam soluk metin.
                                                color: cooling ? muted : null,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                              ),
                              const SizedBox(height: 4),
                              AuthLinkRow(
                                prompt: 'Zaten bir hesabınız var mı? ',
                                actionLabel: 'Giriş Yapın',
                                actionKey: const Key('btn_back_to_login'),
                                onTap: _isLoading ? null : () => Navigator.of(context).pop(),
                              ),
                            ],
                          ),
                        ),
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
