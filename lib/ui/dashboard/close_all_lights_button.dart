import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/automation_state.dart';
import '../common/confirm_dialogs.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/orb/progress_arc.dart';

/// "Hepsini Kapat" düğmesi (pano bandı ve ayarlar sayfası ortak kullanır).
///
/// * Çalışırken pasif ve ilerleme gösterir (çift dokunuş yok).
/// * Hata yakalanır ve Türkçe mesajla gösterilir (ham istisna metni yok).
/// * Başarıda **gerçek** kapatılan lamba sayısı bildirilir ([AutomationState.closeAllOpenLights]
///   sunucunun saydığı sayıyı döndürür); `0` ise "açık lamba bulunamadı" denir.
///
/// [color] yalnızca kenarlıklı varyantın ([filled] = `false`) rengidir ve **7 aileden biri** olmalıdır
/// (varsayılan `AppFamilies.sky.deep`: tema çerçeveli düğmesinin mavisi); ham Material rengi verilirse
/// (`ButtonTone.familyFor`) en yakın aileye oturtulur. Dolgulu varyant tema gradyanını kullanır.
///
/// Anahtar: `Key('btn_close_all_lights')`.
class CloseAllLightsButton extends StatefulWidget {
  const CloseAllLightsButton({
    super.key,
    this.color,
    this.filled = true,
  });

  /// Kenarlıklı varyantın rengi; `null` ise `AppFamilies.sky.deep` (ailenin rengi `const` ifadeyle okunamadığı
  /// için varsayılan yapım anında çözülür).
  final Color? color;

  /// `true`: dolgulu düğme, `false`: kenarlıklı metin düğmesi.
  final bool filled;

  @override
  State<CloseAllLightsButton> createState() => _CloseAllLightsButtonState();
}

class _CloseAllLightsButtonState extends State<CloseAllLightsButton> {
  bool _busy = false;

  Color get _color => widget.color ?? AppFamilies.sky.deep;

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
    final color = _color;
    final progress = ProgressArc(
      diameter: 16,
      strokeWidth: 2,
      color: widget.filled ? Colors.white : AppTheme.readableAccent(context, color),
    );
    final label = Text(
      _busy ? 'Kapatılıyor…' : 'Hepsini Kapat',
      style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold),
    );

    if (widget.filled) {
      return ElevatedButton(
        key: const Key('btn_close_all_lights'),
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          // Tema gradyanı (sky -> cyan) ve stadium şekli uygulanır; yalnız boyut/dolgu burada.
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
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
    // Kenar: tüm çerçeveli düğmelerle AYNI tek ton kuralı ([AppTheme.outlinedBorderOfColor]: renk önce ailesine oturtulur; kenar
    // iki temada kart / sayfa / diyalog yüzeylerinde ≥ 3:1). Eskiden elle `family.deep@.75` (açıkta amber ≈ 2.3:1) çiziliyordu.
    return OutlinedButton(
      key: const Key('btn_close_all_lights'),
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: AppTheme.readableAccent(context, color),
        side: BorderSide(color: AppTheme.outlinedBorderOfColor(context, color), width: 1.5),
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
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
