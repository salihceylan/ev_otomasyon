import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../services/automation_state.dart';
import '../../theme/app_theme.dart';

class ForgotPasswordPage extends StatefulWidget {
  const ForgotPasswordPage({super.key});

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  final _formKey = GlobalKey<FormState>();
  final _resetFormKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _otpController = TextEditingController();
  final _newPasswordController = TextEditingController();

  bool _isLoading = false;
  bool _isSent = false;
  bool _isResetting = false;
  bool _isCompleted = false;
  String? _otpInfo;

  @override
  void dispose() {
    _emailController.dispose();
    _otpController.dispose();
    _newPasswordController.dispose();
    super.dispose();
  }

  Future<void> _handleResetPassword() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      AutomationState? state;
      try {
        state = context.read<AutomationState>();
      } catch (_) {}

      if (state != null) {
        final res = await state.forgotPassword(_emailController.text.trim());
        if (res['otp'] != null) {
          _otpInfo = res['otp'].toString();
        }
      } else {
        await Future.delayed(const Duration(milliseconds: 1000));
      }

      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _isSent = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Hata: ${e.toString().replaceAll('Exception: ', '')}'),
          backgroundColor: AppTheme.accentRed,
        ),
      );
    }
  }

  Future<void> _handleConfirmNewPassword() async {
    if (!_resetFormKey.currentState!.validate()) return;

    setState(() => _isResetting = true);

    try {
      AutomationState? state;
      try {
        state = context.read<AutomationState>();
      } catch (_) {}

      if (state != null) {
        await state.resetPassword(
          identifier: _emailController.text.trim(),
          otpCode: _otpController.text.trim(),
          newPassword: _newPasswordController.text,
        );
      } else {
        await Future.delayed(const Duration(milliseconds: 600));
      }

      if (!mounted) return;
      setState(() {
        _isResetting = false;
        _isCompleted = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isResetting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Hata: ${e.toString().replaceAll('Exception: ', '')}'),
          backgroundColor: AppTheme.accentRed,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Şifre Sıfırlama'),
        backgroundColor: Colors.transparent,
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: _isCompleted
                  ? _buildCompletedView()
                  : _isSent
                      ? _buildSuccessView()
                      : _buildFormView(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFormView() {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.primaryBlue.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.lock_reset_rounded,
              color: AppTheme.primaryBlueLight,
              size: 54,
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Şifrenizi mi Unuttunuz?',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Kayıtlı e-posta adresinizi veya telefonunuzu girin. Size şifrenizi sıfırlamanız için doğrulama kodu iletilecektir.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: AppTheme.textMuted,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 32),
          TextFormField(
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            style: const TextStyle(color: AppTheme.textPrimary),
            decoration: InputDecoration(
              labelText: 'E-Posta Adresi veya Telefon',
              labelStyle: const TextStyle(color: AppTheme.textMuted),
              prefixIcon: const Icon(Icons.email_outlined, color: AppTheme.textMuted),
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
            ),
            validator: (val) {
              if (val == null || val.trim().isEmpty) {
                return 'Lütfen e-posta adresinizi girin';
              }
              final trimmed = val.trim();
              final isEmail = RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(trimmed);
              final isPhone = RegExp(r'^\+?[0-9]{10,14}$').hasMatch(trimmed);
              if (!isEmail && !isPhone) {
                return 'Geçerli bir e-posta adresi girin';
              }
              return null;
            },
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: _isLoading ? null : _handleResetPassword,
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
                    'Sıfırlama Bağlantısı Gönder',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
          ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text(
              'Giriş Ekranına Dön',
              style: TextStyle(color: AppTheme.textMuted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSuccessView() {
    return Form(
      key: _resetFormKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.accentGreen.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.mark_email_read_outlined,
              color: AppTheme.accentGreen,
              size: 54,
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'Talimatlar Gönderildi',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '${_emailController.text} adresine şifre sıfırlama yönergeleri iletildi. Lütfen gelen kutunuzu kontrol edin.',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 14,
              color: AppTheme.textMuted,
              height: 1.4,
            ),
          ),
          if (_otpInfo != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.accentAmber.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppTheme.accentAmber.withValues(alpha: 0.4)),
              ),
              child: Text(
                'Geliştirici / Test OTP Kodu: $_otpInfo',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppTheme.accentAmber, fontWeight: FontWeight.bold, fontSize: 13),
              ),
            ),
          ],
          const SizedBox(height: 24),
          TextFormField(
            controller: _otpController,
            keyboardType: TextInputType.number,
            maxLength: 6,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppTheme.textPrimary, letterSpacing: 6, fontSize: 20, fontWeight: FontWeight.bold),
            decoration: InputDecoration(
              counterText: '',
              labelText: '6 Haneli Doğrulama Kodu',
              labelStyle: const TextStyle(color: AppTheme.textMuted),
              filled: true,
              fillColor: AppTheme.cardDark,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
            validator: (val) {
              if (val == null || val.trim().length < 4) {
                return 'Lütfen gelen doğrulama kodunu girin';
              }
              return null;
            },
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _newPasswordController,
            obscureText: true,
            style: const TextStyle(color: AppTheme.textPrimary),
            decoration: InputDecoration(
              labelText: 'Yeni Şifre (En az 6 karakter)',
              labelStyle: const TextStyle(color: AppTheme.textMuted),
              prefixIcon: const Icon(Icons.lock_outline, color: AppTheme.textMuted),
              filled: true,
              fillColor: AppTheme.cardDark,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
            validator: (val) {
              if (val == null || val.length < 6) {
                return 'Şifre en az 6 karakter olmalıdır';
              }
              return null;
            },
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: _isResetting ? null : _handleConfirmNewPassword,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.accentGreen,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: _isResetting
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Yeni Şifreyi Kaydet', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Giriş Ekranına Dön', style: TextStyle(color: AppTheme.textMuted)),
          ),
        ],
      ),
    );
  }

  Widget _buildCompletedView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppTheme.accentGreen.withValues(alpha: 0.15),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.check_circle_outline, color: AppTheme.accentGreen, size: 56),
        ),
        const SizedBox(height: 20),
        const Text(
          'Şifreniz Güncellendi',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: AppTheme.textPrimary),
        ),
        const SizedBox(height: 12),
        const Text(
          'Şifreniz başarıyla değiştirildi. Artık yeni şifrenizle giriş yapabilirsiniz.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, color: AppTheme.textMuted, height: 1.4),
        ),
        const SizedBox(height: 28),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.primaryBlue,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: const Text('Giriş Yap', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}
