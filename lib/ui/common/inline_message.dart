import 'package:flutter/material.dart';

import '../motion/motion.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// Formlar/diyaloglar içinde satır içi (SnackBar olmayan) durum iletisi: hata, uyarı, bilgi, başarı.
///
/// Renk **ve** simge birlikte kullanılır (renge bağımlı olmayan gösterge); metin tema rengine göre
/// okunur. [liveRegion] ekran okuyucuya değişiklikleri duyurur.
///
/// **Okunurluk (WP-F4):** kutu OPAK bir tabanın ([SurfaceTokens.cardBottom]) üzerine vurgu tonu bindirilerek
/// çizilir: arkadaki devre fotoğrafı/izleri metnin altından geçmez (eskiden yarı saydam %12 tondu). Simge ve
/// kenar açık temada AA kontrastlı tonla ([AppTheme.readableAccent]) çizilir; ham amber/yeşil açık zeminde
/// ~1.8-2.5:1'di.
///
/// **Köşe:** [AppRadius.r16] (kart/diyalog dili: kartlar r20, diyalog r24; alan çerçevesi r12'den AYRIŞIR). Eskiden r12
/// idi: sayfa düzeyinde duran hata kutusu (aile listesi hatası) hemen yanındaki r20 kartlardan keskin köşeyle ayrılıyordu.
enum InlineMessageKind { error, warning, info, success }

class InlineMessage extends StatelessWidget {
  const InlineMessage(this.message, {super.key, this.kind = InlineMessageKind.error, this.trailing});

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
    final dark = AppTheme.isDark(context);
    final accent = _color;
    // Okunur ton: açık temada metin/simge/kenar AA (4.5:1) sağlayan koyu ton, koyuda zaten yeterli.
    final ink = AppTheme.readableAccent(context, accent);
    final base = SurfaceTokens.of(dark ? Brightness.dark : Brightness.light).cardBottom;
    final fill = Color.alphaBlend(accent.withValues(alpha: dark ? 0.14 : 0.12), base);
    final border = (dark ? accent : ink).withValues(alpha: dark ? 0.40 : 0.50);
    // Mikro-hareket: ileti ilk göründüğünde (ya da türü değiştiğinde; geri sayım gibi metin güncellemelerinde TEKRAR oynamaz) kısa (220 ms) kayma + solma, tek sefer.
    // `MotionMode.off` (varsayılan) ve "hareketi azalt"ta anında görünür; girdiyi bloklamaz.
    return StaggeredEntrance(
      key: ValueKey<InlineMessageKind>(kind),
      index: 0,
      offset: -8,
      child: Semantics(
        liveRegion: true,
        container: true,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(AppRadius.r16),
            border: Border.all(color: border),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(_icon, color: ink, size: 20),
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
                    Text(message, style: TextStyle(color: AppTheme.getTextPrimary(context), fontSize: 12.5, height: 1.35)),
                    ?trailing,
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
