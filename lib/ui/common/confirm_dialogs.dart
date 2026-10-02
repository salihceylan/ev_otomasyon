import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../services/automation_state.dart';
import '../../utils/friendly_error.dart';
import '../pages/auth/social_sign_in.dart';
import '../theme/app_theme.dart';

// =============================================================================
// Paylaşılan onay / hata yardımcıları (WP-E2). İMZALAR SABİTTİR: E1 ve F paketleri kullanır.
//
//  * [ConfirmDestructiveDialog]  -> yıkıcı eylemi YAZARAK onaylatır ("SİL", UUID'nin son 4 hanesi ...)
//  * [confirmAndLogout]          -> onay + çıkış + Navigator yığınını ilk rotaya kadar temizleme
//  * [showFriendlyError]         -> hatayı ham istisna metni göstermeden Türkçe SnackBar ile bildirir
//
// Erişilebilir test anahtarları:
//   Key('field_confirm_phrase'), Key('btn_confirm_destructive'), Key('btn_cancel_destructive'),
//   Key('btn_logout_confirm'),   Key('btn_logout_cancel'),      Key('snack_friendly_error').
// =============================================================================

/// Türkçe büyük/küçük harf ve noktalı/noktasız i ayrımını katlayarak karşılaştırma için
/// normalleştirir: `SİL`, `sil`, `SIL`, `Sıl` hepsi `sil` olur. Baştaki/sondaki boşluk atılır.
@visibleForTesting
String foldConfirmText(String input) {
  final b = StringBuffer();
  for (final rune in input.trim().runes) {
    if (rune == 0x0307) continue; // birleşik nokta (ayrışık 'İ' girişi)
    final ch = String.fromCharCode(rune);
    switch (ch) {
      case 'İ':
      case 'I':
      case 'ı':
        b.write('i');
      default:
        b.write(ch.toLowerCase());
    }
  }
  return b.toString();
}

/// [input], [phrase] ile (büyük/küçük harf ve Türkçe i/ı farkı gözetilmeden) aynı mı?
/// Boş ifade hiçbir girdiyle eşleşmez (yanlışlıkla "boş = onay" olmasın).
bool confirmPhraseMatches(String input, String phrase) {
  final expected = foldConfirmText(phrase);
  if (expected.isEmpty) return false;
  return foldConfirmText(input) == expected;
}

/// Yıkıcı bir eylemi (silme, devir, sıfırlama ...) kullanıcıya bir ifade **yazdırarak** onaylatır.
///
/// Düğme, ifade doğru yazılana kadar pasiftir. Sonuç: yalnızca ifade doğru yazılıp onay
/// düğmesine basıldıysa `true`; vazgeç / dışarı dokunma / geri tuşu `false`.
class ConfirmDestructiveDialog extends StatefulWidget {
  const ConfirmDestructiveDialog({
    super.key,
    required this.title,
    required this.message,
    this.confirmPhrase = 'SİL',
    this.confirmLabel = 'Sil',
    this.cancelLabel = 'Vazgeç',
    this.icon = Icons.warning_amber_rounded,
  });

  final String title;
  final String message;

  /// Kullanıcının yazması gereken ifade (örn. `SİL` ya da cihaz UUID'sinin son 4 hanesi).
  final String confirmPhrase;
  final String confirmLabel;
  final String cancelLabel;
  final IconData icon;

  /// Diyaloğu gösterir. `true` yalnızca ifade doğru yazılıp onaylandığında döner.
  static Future<bool> show(
    BuildContext context, {
    required String title,
    required String message,
    String confirmPhrase = 'SİL',
    String confirmLabel = 'Sil',
    String cancelLabel = 'Vazgeç',
    IconData icon = Icons.warning_amber_rounded,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => ConfirmDestructiveDialog(
        title: title,
        message: message,
        confirmPhrase: confirmPhrase,
        confirmLabel: confirmLabel,
        cancelLabel: cancelLabel,
        icon: icon,
      ),
    );
    return result == true;
  }

  @override
  State<ConfirmDestructiveDialog> createState() => _ConfirmDestructiveDialogState();
}

class _ConfirmDestructiveDialogState extends State<ConfirmDestructiveDialog> {
  final TextEditingController _controller = TextEditingController();

  bool get _matches => confirmPhraseMatches(_controller.text, widget.confirmPhrase);

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  void _confirm() {
    if (!_matches) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final muted = AppTheme.getTextMuted(context);
    final primary = AppTheme.getTextPrimary(context);
    return AlertDialog(
      backgroundColor: AppTheme.getSurfaceColor(context),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: AppTheme.getCardBorder(context)),
      ),
      title: Row(
        children: [
          Icon(widget.icon, color: AppTheme.accentRed, size: 26),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              widget.title,
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: primary),
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.message, style: TextStyle(color: muted, fontSize: 13, height: 1.35)),
            const SizedBox(height: 14),
            Text.rich(
              TextSpan(
                style: TextStyle(color: primary, fontSize: 13),
                children: [
                  const TextSpan(text: 'Onaylamak için '),
                  TextSpan(
                    text: widget.confirmPhrase,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: AppTheme.accentRed,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const TextSpan(text: ' yazın:'),
                ],
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('field_confirm_phrase'),
              controller: _controller,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.characters,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _confirm(),
              decoration: InputDecoration(
                isDense: true,
                hintText: widget.confirmPhrase,
                suffixIcon: _matches
                    ? const Icon(Icons.check_circle_rounded, color: AppTheme.accentGreen, size: 20)
                    : null,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('btn_cancel_destructive'),
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(widget.cancelLabel, style: TextStyle(color: muted)),
        ),
        ElevatedButton(
          key: const Key('btn_confirm_destructive'),
          onPressed: _matches ? _confirm : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.accentRed,
            foregroundColor: Colors.white,
            disabledBackgroundColor: AppTheme.accentRed.withValues(alpha: 0.25),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: Text(widget.confirmLabel, style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }
}

/// Yazı gerektirmeyen basit onay diyaloğu (vazgeç / onayla). Onaylanırsa `true`; vazgeç, dışarı
/// dokunma ve geri tuşu `false`. [destructive] `true` ise onay düğmesi kırmızıdır.
Future<bool> showSimpleConfirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Evet',
  String cancelLabel = 'Vazgeç',
  bool destructive = false,
  IconData icon = Icons.help_outline_rounded,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppTheme.getSurfaceColor(ctx),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: AppTheme.getCardBorder(ctx)),
      ),
      title: Row(
        children: [
          Icon(icon, color: destructive ? AppTheme.accentRed : AppTheme.primaryBlueLight, size: 24),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              title,
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: AppTheme.getTextPrimary(ctx)),
            ),
          ),
        ],
      ),
      content: Text(
        message,
        style: TextStyle(color: AppTheme.getTextMuted(ctx), fontSize: 13, height: 1.35),
      ),
      actions: [
        TextButton(
          key: const Key('btn_simple_cancel'),
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(cancelLabel, style: TextStyle(color: AppTheme.getTextMuted(ctx))),
        ),
        ElevatedButton(
          key: const Key('btn_simple_confirm'),
          onPressed: () => Navigator.of(ctx).pop(true),
          style: ElevatedButton.styleFrom(
            backgroundColor: destructive ? AppTheme.accentRed : AppTheme.primaryBlue,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: Text(confirmLabel, style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
      ],
    ),
  );
  return result == true;
}

bool _logoutRunning = false;

/// Onay ister, [AutomationState.logout] çağırır ve Navigator yığınını ilk rotaya kadar temizler
/// (açık diyaloglar ve itilmiş sayfalar kapanır; kapı [AuthGate] giriş ekranını gösterir).
///
/// Uygulamadaki **tüm** çıkış yolları (profil, çekmece, kısıtlı ekranlar) bunu kullanır.
/// Dönüş: çıkış yapıldıysa `true`; vazgeçildi / zaten sürüyor / başarısız ise `false`.
Future<bool> confirmAndLogout(BuildContext context, AutomationState state) async {
  if (_logoutRunning) return false;
  // Gezgin, await'ler öncesinde alınır: çağıran widget (ör. profil diyaloğu) kapanmış olabilir.
  final navigator = Navigator.of(context, rootNavigator: true);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppTheme.getSurfaceColor(ctx),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: AppTheme.getCardBorder(ctx)),
      ),
      title: Row(
        children: [
          const Icon(Icons.logout_rounded, color: AppTheme.accentRed, size: 24),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              'Çıkış Yapılsın mı?',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: AppTheme.getTextPrimary(ctx),
              ),
            ),
          ),
        ],
      ),
      content: Text(
        'Oturumunuz kapatılacak ve bu cihazdaki güvenli veriler temizlenecek. Devam etmek istiyor musunuz?',
        style: TextStyle(color: AppTheme.getTextMuted(ctx), fontSize: 13, height: 1.35),
      ),
      actions: [
        TextButton(
          key: const Key('btn_logout_cancel'),
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text('Vazgeç', style: TextStyle(color: AppTheme.getTextMuted(ctx))),
        ),
        ElevatedButton(
          key: const Key('btn_logout_confirm'),
          onPressed: () => Navigator.of(ctx).pop(true),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.accentRed,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: const Text('Evet, Çıkış Yap', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
      ],
    ),
  );
  if (confirmed != true) return false;

  _logoutRunning = true;
  try {
    await state.logout();
    unawaited(SocialSignIn.signOutGoogle()); // bir sonraki girişte hesap seçilebilsin
  } catch (e) {
    // Yerel temizlik `logout` içinde ilk adımdır; beklenmedik bir hata yığını temizlemeyi
    // engellememeli. Hata türü dışında bir şey loglanmaz.
    if (kDebugMode) debugPrint('[Çıkış] beklenmeyen hata: ${e.runtimeType}');
  } finally {
    _logoutRunning = false;
  }
  navigator.popUntil((route) => route.isFirst);
  return true;
}

/// [error]'ı ham istisna/sunucu metni göstermeden, Türkçe ve kullanıcıya uygun bir SnackBar ile
/// bildirir ([friendlyError]). [context] kapanmışsa ya da `ScaffoldMessenger` yoksa sessizce çıkar.
void showFriendlyError(BuildContext context, Object? error, {String? fallback}) {
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final message = fallback == null ? friendlyError(error) : friendlyError(error, fallback: fallback);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        key: const Key('snack_friendly_error'),
        content: Text(message),
        backgroundColor: AppTheme.accentRed,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 5),
      ),
    );
}
