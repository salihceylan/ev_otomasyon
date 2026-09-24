import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../services/automation_state.dart';
import '../../theme/app_theme.dart';

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

  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  bool _isLoading = false;

  @override
  void dispose() {
    _fullNameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _handleRegister() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      final state = context.read<AutomationState>();
      final success = await state.register(
        fullName: _fullNameController.text.trim(),
        email: _emailController.text.trim(),
        password: _passwordController.text,
        phone: _phoneController.text.trim().isNotEmpty ? _phoneController.text.trim() : null,
      );

      if (!mounted) return;

      if (success) {
        // Oturum açıldı, AuthGate otomatik Dashboard'a geçecek.
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
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
                  'Kayıt başarısız: ${e.toString().replaceAll('Exception: ', '')}',
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

  @override
  Widget build(BuildContext context) {
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
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Üst Başlık & İkon
                    Center(
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: AppTheme.primaryBlue.withValues(alpha: 0.12),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.person_add_alt_1_rounded,
                          color: AppTheme.primaryBlueLight,
                          size: 44,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      'Yeni Hesap Oluşturun',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Evinizi ve tüm cihazlarınızı güvenle yönetin',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color: AppTheme.textMuted,
                      ),
                    ),
                    const SizedBox(height: 28),

                    // Ad Soyad
                    TextFormField(
                      controller: _fullNameController,
                      textCapitalization: TextCapitalization.words,
                      style: const TextStyle(color: AppTheme.textPrimary),
                      decoration: _inputDecoration(
                        label: 'Ad Soyad',
                        prefixIcon: Icons.person_outline,
                      ),
                      validator: (val) {
                        if (val == null || val.trim().isEmpty) {
                          return 'Lütfen adınızı ve soyadınızı girin';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),

                    // E-posta
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

                    // Telefon (Opsiyonel)
                    TextFormField(
                      controller: _phoneController,
                      keyboardType: TextInputType.phone,
                      style: const TextStyle(color: AppTheme.textPrimary),
                      decoration: _inputDecoration(
                        label: 'Telefon Numarası (İsteğe Bağlı)',
                        prefixIcon: Icons.phone_outlined,
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Şifre
                    TextFormField(
                      controller: _passwordController,
                      obscureText: _obscurePassword,
                      style: const TextStyle(color: AppTheme.textPrimary),
                      decoration: _inputDecoration(
                        label: 'Şifre (En az 6 karakter)',
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
                          return 'Lütfen bir şifre belirleyin';
                        }
                        if (val.length < 6) {
                          return 'Şifre en az 6 karakter olmalıdır';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),

                    // Şifre Tekrar
                    TextFormField(
                      controller: _confirmPasswordController,
                      obscureText: _obscureConfirmPassword,
                      style: const TextStyle(color: AppTheme.textPrimary),
                      decoration: _inputDecoration(
                        label: 'Şifre Tekrar',
                        prefixIcon: Icons.lock_reset,
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscureConfirmPassword ? Icons.visibility_off : Icons.visibility,
                            color: AppTheme.textMuted,
                          ),
                          onPressed: () {
                            setState(() => _obscureConfirmPassword = !_obscureConfirmPassword);
                          },
                        ),
                      ),
                      validator: (val) {
                        if (val == null || val.isEmpty) {
                          return 'Lütfen şifrenizi tekrar girin';
                        }
                        if (val != _passwordController.text) {
                          return 'Şifreler eşleşmiyor';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 28),

                    // Kayıt Ol Butonu
                    ElevatedButton(
                      onPressed: _isLoading ? null : _handleRegister,
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
                              'Kayıt Ol ve Giriş Yap',
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                    ),
                    const SizedBox(height: 16),

                    // Zaten hesabım var
                    Wrap(
                      alignment: WrapAlignment.center,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        const Text(
                          'Zaten bir hesabınız var mı? ',
                          style: TextStyle(color: AppTheme.textMuted, fontSize: 14),
                        ),
                        GestureDetector(
                          onTap: () => Navigator.of(context).pop(),
                          child: const Text(
                            'Giriş Yapın',
                            style: TextStyle(
                              color: AppTheme.primaryBlueLight,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
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
