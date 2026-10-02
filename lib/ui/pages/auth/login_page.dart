import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../services/automation_state.dart';
import '../../../utils/friendly_error.dart';
import '../../common/auth_form.dart';
import '../../common/cooldown.dart';
import '../../common/date_format.dart';
import '../../common/inline_message.dart';
import '../../common/validators.dart';
import '../../theme/app_theme.dart';
import '../wifi_recovery_dialog.dart';
import 'forgot_password_dialog.dart';
import 'magic_link_dialog.dart';
import 'phone_otp_dialog.dart';
import 'register_page.dart';
import 'service_pin_dialog.dart';
import 'social_sign_in.dart';

/// Giriş ekranı: e-posta + şifre, Google, Apple (yalnızca iOS/macOS), SMS kodu, servis PIN'i, yerel mod.
///
/// * Giriş formu yalnızca **boş mu** kontrolü yapar (en az uzunluk politikası kayıtta); şifre
///   **kırpılmaz**, e-posta kırpılır.
/// * Hatalar `friendlyError` ile Türkçe gösterilir; hız sınırında (429) geri sayım ve düğme kilidi.
/// * Oturum süresi dolduysa (`sessionNotice`) açıklayıcı bir ileti gösterilir.
class LoginPage extends StatefulWidget {
  const LoginPage({super.key, this.googleIdTokenProvider, this.appleProvider});

  /// Yalnızca testlerde: Google kimlik jetonu sağlayıcısı (`null` dönerse kullanıcı vazgeçmiştir).
  final Future<String?> Function()? googleIdTokenProvider;

  /// Yalnızca testlerde: Apple kimlik bilgisi sağlayıcısı (`null` dönerse kullanıcı vazgeçmiştir).
  final Future<AppleSignInResult?> Function()? appleProvider;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  late final Cooldown _loginCooldown;

  bool _obscurePassword = true;
  bool _isLoading = false;
  String? _error;
  AutovalidateMode _autovalidate = AutovalidateMode.disabled;

  @override
  void initState() {
    super.initState();
    _loginCooldown = Cooldown(context.read<AutomationState>().clock, () {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _loginCooldown.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _applyRateLimit(Object e) {
    if (e is ApiException && e.isRateLimited) {
      final wait = e.retryAfter ?? e.resendAfter;
      if (wait != null) _loginCooldown.start(wait);
    }
  }

  Future<void> _handleLogin() async {
    if (_isLoading || _loginCooldown.isActive) return;
    setState(() => _autovalidate = AutovalidateMode.onUserInteraction);
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final state = context.read<AutomationState>();
      // E-posta kırpılır; şifre ASLA kırpılmaz (başında/sonunda boşluk geçerli olabilir).
      await state.login(_emailController.text.trim(), _passwordController.text);
      // Başarıda AuthGate otomatik panele geçirir.
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e, fallback: 'Giriş yapılamadı. Lütfen tekrar deneyin.'));
      _applyRateLimit(e);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleGoogleSignIn() async {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final provider = widget.googleIdTokenProvider ?? SocialSignIn.googleIdToken;
      final idToken = await provider();
      if (idToken == null || !mounted) return; // kullanıcı vazgeçti
      // İstemci jetonsuz e-posta göndermez: yalnızca doğrulanmış kimlik jetonu.
      await context.read<AutomationState>().loginWithGoogle(idToken: idToken);
    } on SocialAuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e, fallback: 'Google ile giriş başarısız oldu. Lütfen tekrar deneyin.'));
      _applyRateLimit(e);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleAppleSignIn() async {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final provider = widget.appleProvider ?? SocialSignIn.apple;
      final result = await provider();
      if (result == null || !mounted) return; // iptal: sessiz
      await context.read<AutomationState>().loginWithApple(
            identityToken: result.identityToken,
            fullName: result.fullName,
            nonce: result.rawNonce,
          );
    } on SocialAuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e, fallback: 'Apple ile giriş başarısız oldu. Lütfen tekrar deneyin.'));
      _applyRateLimit(e);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleDirectMode() async {
    if (_isLoading) return;
    final state = context.read<AutomationState>();
    final ok = await state.setMode(AppMode.direct);
    if (!mounted) return;
    if (!ok) {
      setState(() => _error = 'Yerel ağ moduna geçilemedi.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final notice = context.select<AutomationState, String?>((s) => s.sessionNotice);
    final cooling = _loginCooldown.isActive;

    return Scaffold(
      backgroundColor: const Color(0xFF0B1120),
      body: Stack(
        children: [
          Positioned.fill(
            child: Image.asset(
              'assets/images/ai_circuit_bg.jpg',
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => Container(color: const Color(0xFF0B1120)),
            ),
          ),
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    const Color(0xFF0B1120).withValues(alpha: 0.65),
                    const Color(0xFF0B1120).withValues(alpha: 0.88),
                    const Color(0xFF0B1120).withValues(alpha: 0.98),
                  ],
                  stops: const [0.0, 0.40, 0.85],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: AutofillGroup(
                    child: Form(
                      key: _formKey,
                      autovalidateMode: _autovalidate,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const SizedBox(height: 12),
                          _buildLogo(),
                          const SizedBox(height: 20),
                          const Text(
                            'AHBU OTOMASYON',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 2,
                              color: AppTheme.textPrimary,
                              shadows: [Shadow(color: Color(0xFF38BDF8), blurRadius: 14)],
                            ),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            'Yapay Zeka Destekli Akıllı Yaşam',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              letterSpacing: 0.5,
                              color: Color(0xFF7DD3FC),
                            ),
                          ),
                          const SizedBox(height: 28),
                          if (notice != null) ...[
                            InlineMessage.warning(
                              notice,
                              key: const Key('login_session_notice'),
                              trailing: TextButton(
                                key: const Key('btn_dismiss_notice'),
                                onPressed: () => context.read<AutomationState>().clearSessionNotice(),
                                child: const Text('Tamam'),
                              ),
                            ),
                            const SizedBox(height: 16),
                          ],
                          TextFormField(
                            key: const Key('field_email'),
                            controller: _emailController,
                            enabled: !_isLoading,
                            keyboardType: TextInputType.emailAddress,
                            textInputAction: TextInputAction.next,
                            autofillHints: const [AutofillHints.username, AutofillHints.email],
                            autocorrect: false,
                            enableSuggestions: false,
                            style: const TextStyle(color: AppTheme.textPrimary),
                            decoration: authInputDecoration(
                              context,
                              label: 'E-Posta Adresi',
                              prefixIcon: Icons.email_outlined,
                              onDarkBackground: true,
                            ),
                            validator: AuthValidators.emailError,
                          ),
                          const SizedBox(height: 16),
                          TextFormField(
                            key: const Key('field_password'),
                            controller: _passwordController,
                            enabled: !_isLoading,
                            obscureText: _obscurePassword,
                            textInputAction: TextInputAction.done,
                            autofillHints: const [AutofillHints.password],
                            autocorrect: false,
                            enableSuggestions: false,
                            onFieldSubmitted: (_) => _handleLogin(),
                            style: const TextStyle(color: AppTheme.textPrimary),
                            decoration: authInputDecoration(
                              context,
                              label: 'Şifre',
                              prefixIcon: Icons.lock_outline,
                              onDarkBackground: true,
                              suffixIcon: passwordVisibilityButton(
                                key: const Key('btn_toggle_password'),
                                context: context,
                                obscured: _obscurePassword,
                                onDarkBackground: true,
                                onToggle: () => setState(() => _obscurePassword = !_obscurePassword),
                              ),
                            ),
                            // Giriş formu: yalnızca "boş mu" (min uzunluk politikası kayıtta).
                            validator: AuthValidators.loginPasswordError,
                          ),
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              key: const Key('btn_forgot_password'),
                              onPressed: _isLoading ? null : () => ForgotPasswordDialog.show(context),
                              style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4)),
                              child: const Text(
                                'Şifremi Unuttum',
                                style: TextStyle(color: AppTheme.primaryBlueLight, fontSize: 13, fontWeight: FontWeight.w600),
                              ),
                            ),
                          ),
                          if (_error != null) ...[
                            const SizedBox(height: 8),
                            InlineMessage.error(_error!, key: const Key('login_error')),
                          ],
                          const SizedBox(height: 16),
                          ElevatedButton(
                            key: const Key('btn_login'),
                            onPressed: (_isLoading || cooling) ? null : _handleLogin,
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
                                    cooling ? 'Tekrar dene (${formatCountdown(_loginCooldown.remainingSeconds)})' : 'Giriş Yap',
                                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                                  ),
                          ),
                          const SizedBox(height: 20),
                          Wrap(
                            alignment: WrapAlignment.center,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              const Text('Hesabınız yok mu? ', style: TextStyle(color: AppTheme.textMuted, fontSize: 14)),
                              InkWell(
                                key: const Key('btn_register'),
                                onTap: _isLoading
                                    ? null
                                    : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RegisterPage())),
                                // Dokunma hedefi >= 48 dp (erişilebilirlik): metin ortalı, yükseklik en az 48.
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(minHeight: 48),
                                  child: const Padding(
                                    padding: EdgeInsets.symmetric(horizontal: 4),
                                    child: Center(
                                      widthFactor: 1,
                                      child: Text(
                                        'Kayıt Olun',
                                        style: TextStyle(color: AppTheme.primaryBlueLight, fontWeight: FontWeight.bold, fontSize: 14),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 24),
                          const Row(
                            children: [
                              Expanded(child: Divider(color: AppTheme.cardBorder, thickness: 1)),
                              Padding(
                                padding: EdgeInsets.symmetric(horizontal: 12),
                                child: Text(
                                  'VEYA',
                                  style: TextStyle(color: AppTheme.textMuted, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 1),
                                ),
                              ),
                              Expanded(child: Divider(color: AppTheme.cardBorder, thickness: 1)),
                            ],
                          ),
                          const SizedBox(height: 20),
                          _altButton(
                            key: const Key('btn_google_sign_in'),
                            onPressed: _isLoading ? null : _handleGoogleSignIn,
                            icon: const Icon(Icons.g_mobiledata_rounded, color: Colors.white, size: 28),
                            label: 'Google ile Devam Et',
                            background: AppTheme.surfaceDark.withValues(alpha: 0.6),
                          ),
                          if (SocialSignIn.appleSupported) ...[
                            const SizedBox(height: 10),
                            _altButton(
                              key: const Key('btn_apple_sign_in'),
                              onPressed: _isLoading ? null : _handleAppleSignIn,
                              icon: const Icon(Icons.apple_rounded, color: Colors.white, size: 22),
                              label: 'Apple ile Giriş Yap',
                              background: Colors.black.withValues(alpha: 0.6),
                            ),
                          ],
                          const SizedBox(height: 10),
                          _altButton(
                            key: const Key('btn_phone_otp'),
                            onPressed: _isLoading ? null : () => PhoneOtpDialog.show(context),
                            icon: const Icon(Icons.sms_outlined, color: AppTheme.primaryBlueLight, size: 20),
                            label: 'Telefon Numarası ile Şifresiz Giriş (SMS)',
                            background: AppTheme.surfaceDark.withValues(alpha: 0.4),
                          ),
                          const SizedBox(height: 10),
                          _altButton(
                            key: const Key('btn_magic_link'),
                            onPressed: _isLoading ? null : () => MagicLinkDialog.show(context),
                            icon: const Icon(Icons.link_rounded, color: AppTheme.primaryBlueLight, size: 20),
                            label: 'E-postadaki Bağlantım Var',
                            background: AppTheme.surfaceDark.withValues(alpha: 0.4),
                          ),
                          const SizedBox(height: 16),
                          _altButton(
                            key: const Key('btn_service_pin'),
                            onPressed: _isLoading ? null : () => ServicePinDialog.show(context),
                            icon: const Icon(Icons.handyman_outlined, color: AppTheme.accentAmber, size: 20),
                            label: 'Yetkili Servis Girişi (PIN)',
                            background: AppTheme.surfaceDark.withValues(alpha: 0.5),
                          ),
                          const SizedBox(height: 12),
                          // Wi-Fi kurulum/kurtarma: giriş ve internet GEREKMEZ (pano kendi WPA2 kurulum
                          // ağından anahtarsız Wi-Fi uçlarını açar; teknisyen müşteride internetsizdir).
                          _altButton(
                            key: const Key('btn_wifi_setup'),
                            onPressed: _isLoading ? null : () => WifiRecoveryDialog.show(context),
                            icon: const Icon(Icons.wifi_find_rounded, color: AppTheme.primaryBlueLight, size: 20),
                            label: 'Pano Wi-Fi Kurulumu (İnternet Gerekmez)',
                            background: AppTheme.surfaceDark.withValues(alpha: 0.4),
                          ),
                          const SizedBox(height: 12),
                          _altButton(
                            key: const Key('btn_local_mode'),
                            onPressed: _isLoading ? null : _handleDirectMode,
                            icon: const Icon(Icons.wifi_rounded, color: AppTheme.accentGreen, size: 20),
                            label: 'Yerel Ağ Modu (ESP32 Doğrudan Erişim)',
                            background: Colors.transparent,
                            textColor: AppTheme.textMuted,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogo() {
    return Center(
      child: Container(
        height: 104,
        width: 104,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0xFF38BDF8), width: 0.8),
          boxShadow: [
            BoxShadow(color: const Color(0xFF38BDF8).withValues(alpha: 0.35), blurRadius: 30, spreadRadius: 4),
          ],
        ),
        child: ClipOval(
          child: Image.asset(
            'assets/images/round_app_logo.png',
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) => Container(
              color: AppTheme.surfaceDark,
              child: const Icon(Icons.home_work_rounded, color: Color(0xFF38BDF8), size: 54),
            ),
          ),
        ),
      ),
    );
  }

  Widget _altButton({
    required Key key,
    required VoidCallback? onPressed,
    required Widget icon,
    required String label,
    required Color background,
    Color textColor = AppTheme.textPrimary,
  }) {
    return OutlinedButton(
      key: key,
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
        side: const BorderSide(color: AppTheme.cardBorder),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        backgroundColor: background,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          icon,
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              style: TextStyle(color: textColor, fontSize: 14, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
