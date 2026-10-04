import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/automation_state.dart';
import '../../services/biometric_auth_service.dart';
import '../common/app_dialogs.dart';
import '../common/auth_form.dart' show buttonSpinner;
import '../common/confirm_dialogs.dart' show AuthDialogActions, AuthDialogShell, authPrimaryLabel, authSecondaryLabel;
import '../common/inline_message.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'settings/appearance_cards.dart' show biometricIconFor;

/// İlk giriş sonrası tek seferlik biyometrik giriş onay diyaloğu.
///
/// * Doğrulama sürerken **meşgul** durumdadır: düğmeler pasif, çift dokunuş ikinci istek başlatmaz
///   ve geri tuşu diyaloğu kapatmaz.
/// * Doğrulama başarısız/iptal olursa diyalog **açık kalır** ve açık bir geri bildirim gösterir
///   (yeniden denenebilir ya da "Daha Sonra" seçilebilir).
/// * Platform istisnaları yakalanır; ham hata metni gösterilmez.
/// * Geri tuşu (meşgul değilken) "Daha Sonra" gibi davranır: istem tekrar tekrar çıkmaz. Dışarıdan
///   (programatik) kapatılması ise karar değildir: tercih yazılmaz, istem uygun anda yeniden sunulabilir.
class BiometricPromptDialog extends StatefulWidget {
  final String biometricLabel;

  const BiometricPromptDialog({super.key, this.biometricLabel = 'Face ID / Parmak İzi'});

  static Future<bool?> show(BuildContext context, {String label = 'Face ID / Parmak İzi'}) {
    return showAppDialog<bool>(
      context,
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
  String? _feedback;

  @override
  void initState() {
    super.initState();
    _state = context.read<AutomationState>();
  }

  Future<void> _later() async {
    if (_busy) return;
    setState(() => _busy = true);
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
      _feedback = '${biometricFailureMessage(_state.biometricService.lastFailure, label: widget.biometricLabel)} '
          'Tekrar deneyebilir veya daha sonra Ayarlar bölümünden etkinleştirebilirsiniz.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        // Sistem geri tuşu (didPop=false, meşgul değilken) "Daha Sonra" sayılır. Programatik kapanış
        // (çıkış, kilit, derin bağlantı) didPop=true ile gelir ve karar DEĞİLDİR: tercih yazılmaz.
        if (!didPop && !_busy) unawaited(_later());
      },
      // Ortak diyalog kabuğu: auth/onay akışındaki tüm diyaloglarla aynı yüzey, başlık ve eylem satırı.
      child: AuthDialogShell(
        // Simge biyometrik türü izler: "Face ID Kullanılsın mı?" başlığında yüz simgesi (karma etiket: parmak izi).
        icon: biometricIconFor(widget.biometricLabel),
        family: AppFamilies.emerald,
        title: '${widget.biometricLabel} Kullanılsın mı?',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Sonraki girişlerinizde ${widget.biometricLabel} ile şifre yazmadan evinize hızlıca erişebilirsiniz.',
              style: TextStyle(color: AppTheme.getTextMuted(context), fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.getCardColor(context),
                borderRadius: BorderRadius.circular(AppRadius.r12),
                border: Border.all(color: AppTheme.getCardBorder(context)),
              ),
              child: Row(
                children: [
                  Icon(Icons.security_rounded, color: AppTheme.infoText(context), size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Oturum bilgileriniz cihazınızın donanımsal güvenlik kasasında (Keystore/Keychain) saklanır.',
                      style: TextStyle(color: AppTheme.getTextPrimary(context), fontSize: 12.5, height: 1.35),
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
        actions: AuthDialogActions(
          secondaryLabel: 'Daha Sonra',
          secondary: TextButton(
            key: const Key('btn_biometric_later'),
            onPressed: _busy ? null : _later,
            child: authSecondaryLabel(context, 'Daha Sonra'),
          ),
          // Ölçüm: en uzun birincil etiket (düzen geri bildirim gelince sıçramaz).
          primaryLabel: 'Evet, Etkinleştir',
          primary: ElevatedButton(
            key: const Key('btn_biometric_enable'),
            onPressed: _busy ? null : _enable,
            child: _busy ? buttonSpinner() : authPrimaryLabel(_feedback == null ? 'Evet, Etkinleştir' : 'Tekrar Dene'),
          ),
        ),
      ),
    );
  }
}
