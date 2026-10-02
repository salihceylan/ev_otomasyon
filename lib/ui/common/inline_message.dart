import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Formlar/diyaloglar içinde satır içi (SnackBar olmayan) durum iletisi: hata, uyarı, bilgi, başarı.
///
/// Renk **ve** simge birlikte kullanılır (renge bağımlı olmayan gösterge); metin tema rengine göre
/// okunur. [liveRegion] ekran okuyucuya değişiklikleri duyurur.
enum InlineMessageKind { error, warning, info, success }

class InlineMessage extends StatelessWidget {
  const InlineMessage(
    this.message, {
    super.key,
    this.kind = InlineMessageKind.error,
    this.trailing,
  });

  const InlineMessage.error(String message, {Key? key, Widget? trailing})
      : this(message, key: key, kind: InlineMessageKind.error, trailing: trailing);

  const InlineMessage.warning(String message, {Key? key, Widget? trailing})
      : this(message, key: key, kind: InlineMessageKind.warning, trailing: trailing);

  const InlineMessage.info(String message, {Key? key, Widget? trailing})
      : this(message, key: key, kind: InlineMessageKind.info, trailing: trailing);

  const InlineMessage.success(String message, {Key? key, Widget? trailing})
      : this(message, key: key, kind: InlineMessageKind.success, trailing: trailing);

  final String message;
  final InlineMessageKind kind;

  /// Sağ tarafta isteğe bağlı eylem (ör. "Tekrar dene" düğmesi).
  final Widget? trailing;

  Color get _color {
    switch (kind) {
      case InlineMessageKind.error:
        return AppTheme.accentRed;
      case InlineMessageKind.warning:
        return AppTheme.accentAmber;
      case InlineMessageKind.info:
        return AppTheme.primaryBlueLight;
      case InlineMessageKind.success:
        return AppTheme.accentGreen;
    }
  }

  IconData get _icon {
    switch (kind) {
      case InlineMessageKind.error:
        return Icons.error_outline_rounded;
      case InlineMessageKind.warning:
        return Icons.warning_amber_rounded;
      case InlineMessageKind.info:
        return Icons.info_outline_rounded;
      case InlineMessageKind.success:
        return Icons.check_circle_outline_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _color;
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(_icon, color: color, size: 20),
            const SizedBox(width: 10),
            // Mesaj ve eylem sığıyorsa aynı satırda (eylem sağda), sığmıyorsa (dar ekran, büyük yazı,
            // uzun etiket) eylem mesajın altına iner: `Row` içindeki sınırsız genişlikli düğme taşırdı.
            Expanded(
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: [
                  Text(
                    message,
                    style: TextStyle(color: AppTheme.getTextPrimary(context), fontSize: 12.5, height: 1.35),
                  ),
                  ?trailing,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
