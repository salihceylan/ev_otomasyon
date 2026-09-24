import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../services/automation_state.dart';
import '../../theme/app_theme.dart';

/// ADIM 18: Telefon Numarası ile Şifresiz Giriş (OTP) Diyaloğu
class PhoneOtpDialog extends StatefulWidget {
  const PhoneOtpDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PhoneOtpDialog(),
    );
  }

  @override
  State<PhoneOtpDialog> createState() => _PhoneOtpDialogState();
}

class _PhoneOtpDialogState extends State<PhoneOtpDialog> {
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();

  bool _isCodeSent = false;
  bool _isLoading = false;
  int _countdown = 0;
  Timer? _timer;

  @override
  void dispose() {
    _phoneController.dispose();
    _codeController.dispose();
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
    final phone = _phoneController.text.trim();
    if (phone.length < 10) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Lütfen geçerli bir telefon numarası giriniz (örn: 05xxxxxxxxx)'),
          backgroundColor: AppTheme.accentRed,
        ),
      );
      return;
    }

    setState(() => _isLoading = true);
    try {
      final state = context.read<AutomationState>();
      final res = await state.sendPhoneOtp(phone);
      if (!mounted) return;

      setState(() {
        _isCodeSent = true;
      });
      _startCountdown(res['expires_in'] as int? ?? 180);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(res['message'] as String? ?? 'Doğrulama kodu gönderildi'),
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

  Future<void> _handleVerifyCode() async {
    final phone = _phoneController.text.trim();
    final code = _codeController.text.trim();

    if (code.length != 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Lütfen 6 haneli doğrulama kodunu giriniz'),
          backgroundColor: AppTheme.accentRed,
        ),
      );
      return;
    }

    setState(() => _isLoading = true);
    try {
      final state = context.read<AutomationState>();
      await state.verifyPhoneOtp(phone, code);
      if (!mounted) return;
      Navigator.of(context).pop(); // Başarılı giriş, diyalog kapanır
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Doğrulama hatası: $e'),
          backgroundColor: AppTheme.accentRed,
        ),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.surfaceDark,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: AppTheme.cardBorder, width: 1.2),
      ),
      titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
      contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppTheme.primaryBlue.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.sms_rounded, color: AppTheme.primaryBlueLight, size: 24),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Şifresiz SMS Girişi',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 8),
            Text(
              !_isCodeSent
                  ? 'Telefon numaranızı girin, size 6 haneli tek kullanımlık doğrulama kodu gönderelim.'
                  : '${_phoneController.text.trim()} numarasına gönderilen 6 haneli kodu giriniz.',
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 18),

            // Telefon Numarası Alanı
            TextField(
              controller: _phoneController,
              enabled: !_isCodeSent && !_isLoading,
              keyboardType: TextInputType.phone,
              style: const TextStyle(color: AppTheme.textPrimary, fontSize: 15),
              decoration: InputDecoration(
                labelText: 'Telefon Numarası',
                hintText: '05xxxxxxxxx',
                prefixIcon: const Icon(Icons.phone_iphone_rounded, color: AppTheme.primaryBlueLight, size: 20),
                filled: true,
                fillColor: AppTheme.cardDark,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: AppTheme.cardBorder),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: AppTheme.primaryBlue, width: 1.8),
                ),
              ),
            ),

            // Eğer kod gönderildiyse 6 haneli Kod Alanı
            if (_isCodeSent) ...[
              const SizedBox(height: 16),
              TextField(
                controller: _codeController,
                enabled: !_isLoading,
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
                  labelText: 'Doğrulama Kodu',
                  hintText: '••••••',
                  hintStyle: const TextStyle(color: AppTheme.textMuted, letterSpacing: 8),
                  prefixIcon: const Icon(Icons.pin_rounded, color: AppTheme.accentGreen, size: 20),
                  filled: true,
                  fillColor: AppTheme.cardDark,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: AppTheme.cardBorder),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: AppTheme.accentGreen, width: 1.8),
                  ),
                ),
              ),
              const SizedBox(height: 8),

              // Geri Sayım & Yeniden Gönder
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _countdown > 0 ? 'Kalan süre: ${_countdown}s' : 'Süre doldu',
                    style: TextStyle(
                      color: _countdown > 0 ? AppTheme.textMuted : AppTheme.accentRed,
                      fontSize: 12,
                    ),
                  ),
                  if (_countdown == 0)
                    TextButton(
                      onPressed: _isLoading ? null : _handleSendCode,
                      style: TextButton.styleFrom(padding: EdgeInsets.zero),
                      child: const Text(
                        'Tekrar Kod İste',
                        style: TextStyle(color: AppTheme.primaryBlueLight, fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.of(context).pop(),
          child: const Text('İptal', style: TextStyle(color: AppTheme.textMuted)),
        ),
        ElevatedButton(
          onPressed: _isLoading
              ? null
              : (!_isCodeSent ? _handleSendCode : _handleVerifyCode),
          style: ElevatedButton.styleFrom(
            backgroundColor: !_isCodeSent ? AppTheme.primaryBlue : AppTheme.accentGreen,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          ),
          child: _isLoading
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : Text(
                  !_isCodeSent ? 'Kod Gönder' : 'Giriş Yap',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
        ),
      ],
    );
  }
}

