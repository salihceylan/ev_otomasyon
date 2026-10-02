import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/automation_state.dart';
import '../common/confirm_dialogs.dart';
import '../theme/app_theme.dart';

/// "Hepsini Kapat" düğmesi (pano bandı ve ayarlar sayfası ortak kullanır).
///
/// * Çalışırken pasif ve ilerleme gösterir (çift dokunuş yok).
/// * Hata yakalanır ve Türkçe mesajla gösterilir (ham istisna metni yok).
/// * Başarıda **gerçek** kapatılan lamba sayısı bildirilir ([AutomationState.closeAllOpenLights]
///   sunucunun saydığı sayıyı döndürür); `0` ise "açık lamba bulunamadı" denir.
///
/// Anahtar: `Key('btn_close_all_lights')`.
class CloseAllLightsButton extends StatefulWidget {
  const CloseAllLightsButton({
    super.key,
    this.color = Colors.indigoAccent,
    this.filled = true,
  });

  final Color color;

  /// `true`: dolgulu düğme, `false`: kenarlıklı metin düğmesi.
  final bool filled;

  @override
  State<CloseAllLightsButton> createState() => _CloseAllLightsButtonState();
}

class _CloseAllLightsButtonState extends State<CloseAllLightsButton> {
  bool _busy = false;

  Future<void> _closeAll() async {
    if (_busy) return;
    final state = context.read<AutomationState>();
    setState(() => _busy = true);
    int? closed;
    Object? error;
    try {
      closed = await state.closeAllOpenLights();
    } catch (e) {
      error = e;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    if (error != null) {
      showFriendlyError(context, error, fallback: 'Lambalar kapatılamadı. Lütfen tekrar deneyin.');
      return;
    }
    final message = (closed ?? 0) > 0
        ? '$closed açık lamba için kapatma komutu gönderildi.'
        : 'Kapatılacak açık lamba bulunamadı.';
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final canUse = context.select<AutomationState, bool>((s) => s.capabilities.canUseGroupCommands);
    final onPressed = (_busy || !canUse) ? null : _closeAll;
    final progress = SizedBox(
      width: 16,
      height: 16,
      child: CircularProgressIndicator(
        strokeWidth: 2,
        color: widget.filled ? Colors.white : AppTheme.readableAccent(context, widget.color),
      ),
    );
    final label = Text(
      _busy ? 'Kapatılıyor…' : 'Hepsini Kapat',
      style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold),
    );

    if (widget.filled) {
      return ElevatedButton(
        key: const Key('btn_close_all_lights'),
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppTheme.filledAccent(widget.color),
          foregroundColor: Colors.white,
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_busy) ...[progress, const SizedBox(width: 8)],
            Flexible(child: label),
          ],
        ),
      );
    }
    return OutlinedButton(
      key: const Key('btn_close_all_lights'),
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: AppTheme.readableAccent(context, widget.color),
        side: BorderSide(color: widget.color.withValues(alpha: 0.7)),
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_busy) ...[progress, const SizedBox(width: 8)],
          Flexible(child: label),
        ],
      ),
    );
  }
}
