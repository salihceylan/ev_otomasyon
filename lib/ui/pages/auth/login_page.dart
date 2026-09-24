import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import '../../../services/automation_state.dart';
import '../../theme/app_theme.dart';
import 'forgot_password_dialog.dart';
import 'register_page.dart';
import 'phone_otp_dialog.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _obscurePassword = true;
  bool _isLoading = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      final state = context.read<AutomationState>();
      await state.login(
        _emailController.text.trim(),
        _passwordController.text,
      );
      // Başarılı olduğunda AuthGate otomatik DashboardPage'e geçirecek
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.error_outline, color: Colors.white, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Giriş başarısız: ${e.toString().replaceAll('Exception: ', '')}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          backgroundColor: AppTheme.accentRed,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _showServicePinDialog() {
    final pinController = TextEditingController();
    bool isSubmitting = false;

    showDialog(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: AppTheme.surfaceDark,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(color: AppTheme.cardBorder),
              ),
              title: Row(
                children: const [
                  Icon(Icons.build_circle_outlined, color: AppTheme.accentAmber, size: 28),
                  SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      'Teknisyen Girişi',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Ev sahibinin oluşturduğu 6 haneli geçici servis PIN kodunu giriniz.',
                    style: TextStyle(color: AppTheme.textMuted, fontSize: 13, height: 1.4),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: pinController,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 24,
                      letterSpacing: 8,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.textPrimary,
                    ),
                    decoration: InputDecoration(
                      counterText: '',
                      hintText: '••••••',
                      hintStyle: const TextStyle(color: AppTheme.textMuted, letterSpacing: 8),
                      filled: true,
                      fillColor: AppTheme.cardDark,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: AppTheme.cardBorder),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: AppTheme.cardBorder),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: AppTheme.accentAmber, width: 1.8),
                      ),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: isSubmitting ? null : () => Navigator.of(dialogContext).pop(),
                  child: const Text('İptal', style: TextStyle(color: AppTheme.textMuted)),
                ),
                ElevatedButton(
                  onPressed: isSubmitting
                      ? null
                      : () async {
                          final pin = pinController.text.trim();
                          if (pin.length != 6) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Lütfen 6 haneli geçerli PIN giriniz'),
                                backgroundColor: AppTheme.accentRed,
                              ),
                            );
                            return;
                          }

                          setDialogState(() => isSubmitting = true);
                          try {
                            final state = context.read<AutomationState>();
                            await state.loginWithServicePin(pin);
                            if (dialogContext.mounted) {
                              Navigator.of(dialogContext).pop();
                            }
                          } catch (e) {
                            setDialogState(() => isSubmitting = false);
                            if (dialogContext.mounted) {
                              ScaffoldMessenger.of(dialogContext).showSnackBar(
                                SnackBar(
                                  content: Text('Servis girişi başarısız: $e'),
                                  backgroundColor: AppTheme.accentRed,
                                ),
                              );
                            }
                          }
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.accentAmber,
                    foregroundColor: Colors.black87,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: isSubmitting
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black87),
                        )
                      : const Text('Doğrula', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _handleDirectMode() {
    final state = context.read<AutomationState>();
    state.setMode(AppMode.direct);
    // Direct moda geçilerek local panele erişim sağlanır
  }

  Future<void> _handleGoogleSignIn() async {
    setState(() => _isLoading = true);
    try {
      final googleSignIn = GoogleSignIn(scopes: ['email', 'profile']);
      final account = await googleSignIn.signIn();
      if (account == null) {
        setState(() => _isLoading = false);
        return;
      }
      final auth = await account.authentication;
      if (!mounted) return;
      final state = context.read<AutomationState>();
      await state.loginWithGoogle(
        idToken: auth.idToken,
        email: account.email,
        name: account.displayName,
        googleId: account.id,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Google ile giriş başarısız: $e'),
          backgroundColor: AppTheme.accentRed,
        ),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleAppleSignIn() async {
    setState(() => _isLoading = true);
    try {
      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
      );
      if (!mounted) return;
      final state = context.read<AutomationState>();
      final name = [credential.givenName, credential.familyName]
          .where((n) => n != null && n.isNotEmpty)
          .join(' ');
      await state.loginWithApple(
        identityToken: credential.identityToken,
        userId: credential.userIdentifier ?? '',
        email: credential.email,
        name: name.isNotEmpty ? name : null,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Apple ile giriş başarısız: $e'),
          backgroundColor: AppTheme.accentRed,
        ),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _handlePhoneOtpLogin() {
    PhoneOtpDialog.show(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B1120),
      body: Stack(
        children: [
          // 1. Elektronik & AI Temalı Arka Plan
          Positioned.fill(
            child: Image.asset(
              'assets/images/ai_circuit_bg.jpg',
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => Container(
                color: const Color(0xFF0B1120),
              ),
            ),
          ),

          // 2. Gradyan Karartma Katmanı
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

          // 3. İçerik Katmanı
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 12),
                    // Kurumsal Logo
                    // Kurumsal Dairesel Logo (Kesinlikle köşeli değil)
                    Center(
                      child: Container(
                        height: 104,
                        width: 104,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: const Color(0xFF38BDF8),
                            width: 0.8,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF38BDF8).withValues(alpha: 0.35),
                              blurRadius: 30,
                              spreadRadius: 4,
                            ),
                          ],
                        ),
                        child: ClipOval(
                          child: Image.asset(
                            'assets/images/round_app_logo.png',
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) => Container(
                              color: AppTheme.surfaceDark,
                              child: const Icon(
                                Icons.home_work_rounded,
                                color: Color(0xFF38BDF8),
                                size: 54,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      'AHBU OTOMASYON',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 2,
                        color: AppTheme.textPrimary,
                        shadows: [
                          Shadow(
                            color: Color(0xFF38BDF8),
                            blurRadius: 14,
                          ),
                        ],
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
                    const SizedBox(height: 32),

                    // E-posta alanı
                    TextFormField(
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      style: const TextStyle(color: AppTheme.textPrimary),
                      decoration: _inputDecoration(
                        label: 'E-Posta Adresi',
                        prefixIcon: Icons.email_outlined,
                      ),
                      validator: (val) {
                        if (val == null || val.trim().isEmpty) {
                          return 'Lütfen e-posta adresinizi girin';
                        }
                        final emailRegex = RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$');
                        if (!emailRegex.hasMatch(val.trim())) {
                          return 'Geçerli bir e-posta adresi girin';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),

                    // Şifre alanı
                    TextFormField(
                      controller: _passwordController,
                      obscureText: _obscurePassword,
                      style: const TextStyle(color: AppTheme.textPrimary),
                      decoration: _inputDecoration(
                        label: 'Şifre',
                        prefixIcon: Icons.lock_outline,
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscurePassword ? Icons.visibility_off : Icons.visibility,
                            color: AppTheme.textMuted,
                          ),
                          onPressed: () {
                            setState(() => _obscurePassword = !_obscurePassword);
                          },
                        ),
                      ),
                      validator: (val) {
                        if (val == null || val.isEmpty) {
                          return 'Lütfen şifrenizi girin';
                        }
                        if (val.length < 6) {
                          return 'Şifre en az 6 karakter olmalıdır';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 8),

                    // Şifremi unuttum butonu
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () => ForgotPasswordDialog.show(context),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                        ),
                        child: const Text(
                          'Şifremi Unuttum',
                          style: TextStyle(
                            color: AppTheme.primaryBlueLight,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Giriş Yap Butonu
                    ElevatedButton(
                      onPressed: _isLoading ? null : _handleLogin,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primaryBlue,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 0,
                      ),
                      child: _isLoading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text(
                              'Giriş Yap',
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                    ),
                    const SizedBox(height: 20),

                    // Kayıt Ol Linki
                    Wrap(
                      alignment: WrapAlignment.center,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        const Text(
                          'Hesabınız yok mu? ',
                          style: TextStyle(color: AppTheme.textMuted, fontSize: 14),
                        ),
                        GestureDetector(
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(builder: (_) => const RegisterPage()),
                            );
                          },
                          child: const Text(
                            'Kayıt Olun',
                            style: TextStyle(
                              color: AppTheme.primaryBlueLight,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 32),

                    // Ayırıcı
                    Row(
                      children: const [
                        Expanded(child: Divider(color: AppTheme.cardBorder, thickness: 1)),
                        Padding(
                          padding: EdgeInsets.symmetric(horizontal: 12),
                          child: Text(
                            'VEYA',
                            style: TextStyle(
                              color: AppTheme.textMuted,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 1,
                            ),
                          ),
                        ),
                        Expanded(child: Divider(color: AppTheme.cardBorder, thickness: 1)),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // ADIM 18: Google ile Giriş Yap Butonu
                    OutlinedButton(
                      onPressed: _isLoading ? null : _handleGoogleSignIn,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        side: const BorderSide(color: AppTheme.cardBorder),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        backgroundColor: AppTheme.surfaceDark.withValues(alpha: 0.6),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: const [
                          Icon(Icons.g_mobiledata_rounded, color: Colors.white, size: 28),
                          SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              'Google ile Devam Et',
                              style: TextStyle(color: AppTheme.textPrimary, fontSize: 14, fontWeight: FontWeight.w600),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),

                    // ADIM 18: Apple ile Giriş Yap Butonu
                    OutlinedButton(
                      onPressed: _isLoading ? null : _handleAppleSignIn,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        side: const BorderSide(color: AppTheme.cardBorder),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        backgroundColor: Colors.black.withValues(alpha: 0.6),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: const [
                          Icon(Icons.apple_rounded, color: Colors.white, size: 22),
                          SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              'Apple ile Giriş Yap',
                              style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),

                    // ADIM 18: Telefon Numarası ile Şifresiz Giriş Butonu
                    OutlinedButton.icon(
                      onPressed: _isLoading ? null : _handlePhoneOtpLogin,
                      icon: const Icon(Icons.sms_outlined, color: AppTheme.primaryBlueLight, size: 20),
                      label: const Text(
                        'Telefon Numarası ile Şifresiz Giriş (SMS)',
                        style: TextStyle(color: AppTheme.textPrimary, fontSize: 14),
                        overflow: TextOverflow.ellipsis,
                      ),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        side: const BorderSide(color: AppTheme.cardBorder),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        backgroundColor: AppTheme.surfaceDark.withValues(alpha: 0.4),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Teknisyen / Servis Girişi Butonu
                    OutlinedButton.icon(
                      onPressed: _showServicePinDialog,
                      icon: const Icon(Icons.handyman_outlined, color: AppTheme.accentAmber, size: 20),
                      label: const Text(
                        'Teknisyen / Kurulumcu Girişi (PIN)',
                        style: TextStyle(color: AppTheme.textPrimary, fontSize: 14),
                      ),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        side: const BorderSide(color: AppTheme.cardBorder),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        backgroundColor: AppTheme.surfaceDark.withValues(alpha: 0.5),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Yerel Ağ Modu Butonu
                    OutlinedButton.icon(
                      onPressed: _handleDirectMode,
                      icon: const Icon(Icons.wifi_rounded, color: AppTheme.accentGreen, size: 20),
                      label: const Text(
                        'Yerel Ağ Modu (ESP32 Doğrudan Erişim)',
                        style: TextStyle(color: AppTheme.textMuted, fontSize: 14),
                      ),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        side: const BorderSide(color: AppTheme.cardBorder),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        backgroundColor: Colors.transparent,
                      ),
                    ),
                  ],
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

  InputDecoration _inputDecoration({
    required String label,
    required IconData prefixIcon,
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: AppTheme.textMuted, fontSize: 14),
      prefixIcon: Icon(prefixIcon, color: AppTheme.textMuted),
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: AppTheme.cardDark,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppTheme.cardBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppTheme.cardBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppTheme.primaryBlue, width: 1.8),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppTheme.accentRed),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppTheme.accentRed, width: 1.8),
      ),
    );
  }
}
