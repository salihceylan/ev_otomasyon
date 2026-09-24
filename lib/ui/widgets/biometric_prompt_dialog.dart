import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/automation_state.dart';
import '../theme/app_theme.dart';

/// ADIM 19: İlk Giriş Sonrası Tek Seferlik Biyometrik Onay Diyaloğu
class BiometricPromptDialog extends StatelessWidget {
  final String biometricLabel;

  const BiometricPromptDialog({
    super.key,
    this.biometricLabel = 'Face ID / Parmak İzi',
  });

  static Future<bool?> show(BuildContext context, {String label = 'Face ID / Parmak İzi'}) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => BiometricPromptDialog(biometricLabel: label),
    );
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
              color: AppTheme.accentGreen.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.fingerprint_rounded, color: AppTheme.accentGreen, size: 26),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '$biometricLabel Kullanılsın mı?',
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 17,
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
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 6),
            Text(
              'Sonraki girişlerinizde $biometricLabel ile şifre yazmadan anında (200 ms) evinize erişebilirsiniz.',
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.cardDark,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.cardBorder),
              ),
              child: Row(
                children: [
                  const Icon(Icons.security_rounded, color: AppTheme.primaryBlueLight, size: 20),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Verileriniz cihazınızın donanımsal güvenlik kasasında (Keystore/Keychain) kilitli kalır.',
                      style: TextStyle(color: AppTheme.textPrimary, fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            final state = context.read<AutomationState>();
            await state.dismissBiometricPrompt();
            if (context.mounted) Navigator.of(context).pop(false);
          },
          child: const Text('Daha Sonra', style: TextStyle(color: AppTheme.textMuted)),
        ),
        ElevatedButton(
          onPressed: () async {
            final state = context.read<AutomationState>();
            final success = await state.enableBiometricWithVerification();
            if (context.mounted) {
              Navigator.of(context).pop(success);
              if (success) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('$biometricLabel ile giriş başarıyla etkinleştirildi.'),
                    backgroundColor: AppTheme.accentGreen,
                  ),
                );
              }
            }
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.accentGreen,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          ),
          child: const Text('Evet, Etkinleştir', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }
}

