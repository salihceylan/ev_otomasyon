import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../services/automation_state.dart';
import '../../theme/app_theme.dart';

/// ADIM 20: Sürtünmesiz Şifre Yenileme & Sıfır-Stres Hesap Kurtarma Diyaloğu
class ForgotPasswordDialog extends StatefulWidget {
  const ForgotPasswordDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const ForgotPasswordDialog(),
    );
  }

  @override
  State<ForgotPasswordDialog> createState() => _ForgotPasswordDialogState();
}

class _ForgotPasswordDialogState extends State<ForgotPasswordDialog> {
  final _identifierController = TextEditingController();
  final _codeController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  bool _isCodeSent = false;
  bool _isLoading = false;
  bool _obscureNew = true;
  bool _obscureConfirm = true;
  int _countdown = 0;
  Timer? _timer;

  @override
  void dispose() {
    _identifierController.dispose();
    _codeController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    _timer?.cancel();
    super.dispose();
  }

  void _startCountdown([int seconds = 180]) {
    _timer?.cancel();
    setState(() => _countdown = seconds);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      if (_countdown <= 1) {
        t.cancel();
        setState(() => _countdown = 0);
      } else {
        setState(() => _countdown--);
      }
    });
  }

  Future<void> _handleSendCode() async {
    final identifier = _identifierController.text.trim();
    if (identifier.isEmpty || identifier.length < 3) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Lütfen geçerli bir e-posta veya telefon numarası giriniz'),
          backgroundColor: AppTheme.accentRed,
        ),
      );
      return;
    }

    setState(() => _isLoading = true);
    try {
      final state = context.read<AutomationState>();
      final res = await state.forgotPassword(identifier);
      if (!mounted) return;

      setState(() {
        _isCodeSent = true;
      });
      _startCountdown(res['expires_in'] as int? ?? 180);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(res['message'] as String? ?? 'Kurtarma kodu başarıyla iletildi'),
          backgroundColor: AppTheme.accentGreen,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Kod gönderilemedi: $e'),
          backgroundColor: AppTheme.accentRed,
        ),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleResetPassword() async {
    final identifier = _identifierController.text.trim();
    final code = _codeController.text.trim();
    final newPassword = _newPasswordController.text.trim();
    final confirmPassword = _confirmPasswordController.text.trim();

    if (code.length != 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Lütfen 6 haneli kurtarma kodunu eksiksiz giriniz'),
          backgroundColor: AppTheme.accentRed,
        ),
      );
      return;
    }

    if (newPassword.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Yeni şifre en az 6 karakter olmalıdır'),
          backgroundColor: AppTheme.accentRed,
        ),
      );
      return;
    }

    if (newPassword != confirmPassword) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Girdiğiniz şifreler birbiriyle uyuşmuyor'),
          backgroundColor: AppTheme.accentRed,
        ),
      );
      return;
    }

    setState(() => _isLoading = true);
    try {
      final state = context.read<AutomationState>();
      await state.resetPassword(
        identifier: identifier,
        code: code,
        newPassword: newPassword,
      );

      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Şifreniz başarıyla yenilendi! Oturumunuz açılıyor...'),
          backgroundColor: AppTheme.accentGreen,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Şifre sıfırlama hatası: $e'),
          backgroundColor: AppTheme.accentRed,
        ),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 440),
        decoration: BoxDecoration(
          color: AppTheme.surfaceDark,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: AppTheme.primaryBlue.withValues(alpha: 0.3)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 28,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Başlık & İkon
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppTheme.primaryBlue.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(
                      Icons.lock_reset_rounded,
                      color: AppTheme.primaryBlueLight,
                      size: 26,
                    ),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Şifre Yenileme',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.textPrimary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Sıfır-Stres Hesap Kurtarma',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppTheme.textMuted,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),

              if (!_isCodeSent) ...[
                // 1. ADIM: E-posta veya Telefon Girme
                Text(
                  'Hesabınıza kayıtlı e-posta adresinizi veya telefon numaranızı girin. Size 6 haneli tek kullanımlık geçici bir kurtarma kodu ileteceğiz.',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppTheme.textMuted.withValues(alpha: 0.9),
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 18),

                TextField(
                  controller: _identifierController,
                  keyboardType: TextInputType.emailAddress,
                  style: const TextStyle(color: AppTheme.textPrimary),
                  decoration: InputDecoration(
                    labelText: 'E-posta veya Telefon',
                    labelStyle: const TextStyle(color: AppTheme.textMuted),
                    hintText: 'ornek@ahbu.com veya 05xxxxxxxxx',
                    hintStyle: TextStyle(color: AppTheme.textMuted.withValues(alpha: 0.5)),
                    prefixIcon: const Icon(Icons.person_outline_rounded, color: AppTheme.primaryBlueLight),
                    filled: true,
                    fillColor: AppTheme.bgDark,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: AppTheme.primaryBlue.withValues(alpha: 0.2)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: AppTheme.primaryBlue.withValues(alpha: 0.2)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: AppTheme.primaryBlueLight, width: 1.5),
                    ),
                  ),
                ),
                const SizedBox(height: 22),

                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: _isLoading ? null : () => Navigator.of(context).pop(),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: const Text('İptal', style: TextStyle(color: AppTheme.textMuted)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton(
                        onPressed: _isLoading ? null : _handleSendCode,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primaryBlue,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: _isLoading
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : const Text(
                                'Kod Gönder',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                      ),
                    ),
                  ],
                ),
              ] else ...[
                // 2. ADIM: 6 Haneli Kod ve Yeni Şifre Belirleme
                Text(
                  '${_identifierController.text.trim()} adresine gönderilen 6 haneli kodu ve yeni şifrenizi giriniz.',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppTheme.textMuted.withValues(alpha: 0.9),
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 16),

                // 6 Haneli Kod Alanı
                TextField(
                  controller: _codeController,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 8,
                  ),
                  decoration: InputDecoration(
                    counterText: '',
                    labelText: '6 Haneli Kurtarma Kodu',
                    labelStyle: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
                    hintText: '000000',
                    hintStyle: TextStyle(color: AppTheme.textMuted.withValues(alpha: 0.3), letterSpacing: 8),
                    prefixIcon: const Icon(Icons.pin_rounded, color: AppTheme.primaryBlueLight),
                    filled: true,
                    fillColor: AppTheme.bgDark,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: AppTheme.primaryBlue.withValues(alpha: 0.2)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: AppTheme.primaryBlue.withValues(alpha: 0.2)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: AppTheme.primaryBlueLight, width: 1.5),
                    ),
                  ),
                ),
                const SizedBox(height: 14),

                // Yeni Şifre
                TextField(
                  controller: _newPasswordController,
                  obscureText: _obscureNew,
                  style: const TextStyle(color: AppTheme.textPrimary),
                  decoration: InputDecoration(
                    labelText: 'Yeni Şifre (En az 6 karakter)',
                    labelStyle: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
                    prefixIcon: const Icon(Icons.lock_outline_rounded, color: AppTheme.primaryBlueLight),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureNew ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                        color: AppTheme.textMuted,
                        size: 20,
                      ),
                      onPressed: () => setState(() => _obscureNew = !_obscureNew),
                    ),
                    filled: true,
                    fillColor: AppTheme.bgDark,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: AppTheme.primaryBlue.withValues(alpha: 0.2)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: AppTheme.primaryBlue.withValues(alpha: 0.2)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: AppTheme.primaryBlueLight, width: 1.5),
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                // Yeni Şifre Tekrar
                TextField(
                  controller: _confirmPasswordController,
                  obscureText: _obscureConfirm,
                  style: const TextStyle(color: AppTheme.textPrimary),
                  decoration: InputDecoration(
                    labelText: 'Yeni Şifre Tekrar',
                    labelStyle: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
                    prefixIcon: const Icon(Icons.lock_clock_outlined, color: AppTheme.primaryBlueLight),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureConfirm ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                        color: AppTheme.textMuted,
                        size: 20,
                      ),
                      onPressed: () => setState(() => _obscureConfirm = !_obscureConfirm),
                    ),
                    filled: true,
                    fillColor: AppTheme.bgDark,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: AppTheme.primaryBlue.withValues(alpha: 0.2)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: AppTheme.primaryBlue.withValues(alpha: 0.2)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: AppTheme.primaryBlueLight, width: 1.5),
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                // Güvenlik uyarısı rozeti
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppTheme.accentAmber.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppTheme.accentAmber.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.security_rounded, size: 16, color: AppTheme.accentAmber),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Şifreniz yenilendiğinde diğer tüm cihazlardaki açık oturumlar otomatik kapatılır.',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppTheme.accentAmber.withValues(alpha: 0.9),
                            height: 1.3,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // Geri Sayım / Tekrar Kod İste
                Center(
                  child: _countdown > 0
                      ? Text(
                          'Kalan Süre: ${_countdown ~/ 60}:${(_countdown % 60).toString().padLeft(2, '0')}',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.accentAmber,
                          ),
                        )
                      : TextButton(
                          onPressed: _isLoading ? null : _handleSendCode,
                          child: const Text(
                            'Kodu Tekrar Gönder',
                            style: TextStyle(color: AppTheme.primaryBlueLight, fontSize: 13),
                          ),
                        ),
                ),
                const SizedBox(height: 14),

                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: _isLoading ? null : () => setState(() => _isCodeSent = false),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: const Text('Geri', style: TextStyle(color: AppTheme.textMuted)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton(
                        onPressed: _isLoading ? null : _handleResetPassword,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.accentGreen,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: _isLoading
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : const Text(
                                'Şifreyi Yenile',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

