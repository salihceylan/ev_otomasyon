import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/automation_state.dart';
import '../common/inline_message.dart';
import '../theme/app_theme.dart';

/// İlk giriş sonrası tek seferlik biyometrik giriş onay diyaloğu.
///
/// * Doğrulama sürerken **meşgul** durumdadır: düğmeler pasif, çift dokunuş ikinci istek başlatmaz
///   ve geri tuşu diyaloğu kapatmaz.
/// * Doğrulama başarısız/iptal olursa diyalog **açık kalır** ve açık bir geri bildirim gösterir
///   (yeniden denenebilir ya da "Daha Sonra" seçilebilir).
/// * Platform istisnaları yakalanır; ham hata metni gösterilmez.
/// * Geri tuşu (meşgul değilken) "Daha Sonra" gibi davranır: istem tekrar tekrar çıkmaz.
class BiometricPromptDialog extends StatefulWidget {
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
  State<BiometricPromptDialog> createState() => _BiometricPromptDialogState();
}

class _BiometricPromptDialogState extends State<BiometricPromptDialog> {
  late final AutomationState _state;
  bool _busy = false;
  bool _decided = false;
  String? _feedback;

  @override
  void initState() {
    super.initState();
    _state = context.read<AutomationState>();
  }

  Future<void> _later() async {
    if (_busy) return;
    setState(() => _busy = true);
    _decided = true;
    try {
      await _state.dismissBiometricPrompt();
    } catch (_) {
      // Tercih kaydedilemese de istem kapanır; ağ/depolama hatası kullanıcıyı engellemez.
    }
    if (mounted) Navigator.of(context).pop(false);
  }

  Future<void> _enable() async {
    if (_busy) return; // çift dokunuş koruması (senkron)
    setState(() {
      _busy = true;
      _feedback = null;
    });
    var success = false;
    try {
      success = await _state.enableBiometricWithVerification();
    } catch (_) {
      success = false;
    }
    if (!mounted) return;
    if (success) {
      _decided = true;
      final messenger = ScaffoldMessenger.maybeOf(context);
      Navigator.of(context).pop(true);
      messenger?.showSnackBar(
        SnackBar(
          content: Text('${widget.biometricLabel} ile giriş başarıyla etkinleştirildi.'),
          backgroundColor: AppTheme.accentGreen,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    setState(() {
      _busy = false;
      _feedback = '${widget.biometricLabel} doğrulaması tamamlanamadı. Tekrar deneyebilir veya daha sonra '
          'Ayarlar bölümünden etkinleştirebilirsiniz.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_busy,
      onPopInvokedWithResult: (didPop, result) {
        // Geri tuşuyla kapandıysa (karar verilmeden) istem "daha sonra" sayılır.
        if (didPop && !_decided) {
          _decided = true;
          _state.dismissBiometricPrompt().catchError((Object _) {});
        }
      },
      child: AlertDialog(
        backgroundColor: AppTheme.getSurfaceColor(context),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: AppTheme.getCardBorder(context), width: 1.2),
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
                '${widget.biometricLabel} Kullanılsın mı?',
                style: TextStyle(color: AppTheme.getTextPrimary(context), fontSize: 17, fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis,
                maxLines: 2,
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
                'Sonraki girişlerinizde ${widget.biometricLabel} ile şifre yazmadan evinize hızlıca erişebilirsiniz.',
                style: TextStyle(color: AppTheme.getTextMuted(context), fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.getCardColor(context),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.getCardBorder(context)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.security_rounded, color: AppTheme.primaryBlueLight, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Oturum bilgileriniz cihazınızın donanımsal güvenlik kasasında (Keystore/Keychain) saklanır.',
                        style: TextStyle(color: AppTheme.getTextPrimary(context), fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ),
              if (_feedback != null) ...[
                const SizedBox(height: 12),
                InlineMessage.warning(_feedback!, key: const Key('biometric_feedback')),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const Key('btn_biometric_later'),
            onPressed: _busy ? null : _later,
            child: Text('Daha Sonra', style: TextStyle(color: AppTheme.getTextMuted(context))),
          ),
          ElevatedButton(
            key: const Key('btn_biometric_enable'),
            onPressed: _busy ? null : _enable,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.accentGreen,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            ),
            child: _busy
                ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : Text(_feedback == null ? 'Evet, Etkinleştir' : 'Tekrar Dene', style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
}
