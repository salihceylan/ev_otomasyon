import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../motion/motion_scope.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/orb/orb.dart';
import 'secret_clipboard.dart';
import 'setup_style.dart';

/// Tek seferlik gizli değer satırı (kurulum PIN'i, yerel anahtar ...): değer ekranda **büyük, sabit genişlikli
/// rakamlarla** gösterilir, yanındaki cam düğme [onCopy] çağırır (panoya kopyalama `SecretClipboard` ile 45 sn
/// sonra silinir, arka planda silme başarısızsa ön plana dönünce yeniden denenir). Değer bu widget'ta
/// saklanmaz, loglanmaz.
///
/// Kopyalanınca düğme ✓ gösterir ve çevresinde **silme halkası** [SecretClipboard.defaultWipeAfter] boyunca
/// boşalır (tek sonlu animasyon; süre bitince düğme eski haline döner). `MotionMode.off`: halka çizilmez, ✓ kalır.
///
/// Metin **seçilebilir değildir** (`Text`): sistemin "seç ve kopyala" menüsü silme zamanlayıcısını
/// atlayacağı için panoya tek giriş yolu, silinen yol olan [onCopy] düğmesidir.
class SecretValueRow extends StatefulWidget {
  const SecretValueRow({
    super.key,
    required this.label,
    required this.shown,
    required this.copyKey,
    required this.onCopy,
    this.showWipeRing = true,
  });

  final String label;

  /// Ekranda görünen biçim (ör. "123 456").
  final String shown;
  final Key copyKey;
  final VoidCallback onCopy;

  /// Kopyalanınca düğme çevresinde 45 sn'lik silme halkası çizilsin mi. Çağıran kendi silme sayacını (ör. kartın
  /// altındaki "panoya kopyalandı" satırı) gösteriyorsa `false` verebilir; ✓ geri bildirimi her durumda vardır.
  final bool showWipeRing;

  @override
  State<SecretValueRow> createState() => _SecretValueRowState();
}

class _SecretValueRowState extends State<SecretValueRow> with SingleTickerProviderStateMixin {
  late final AnimationController _wipe = AnimationController(vsync: this, duration: SecretClipboard.defaultWipeAfter);
  bool _copied = false;

  @override
  void dispose() {
    _wipe.dispose();
    super.dispose();
  }

  void _onCopy() {
    widget.onCopy();
    setState(() => _copied = true);
    if (widget.showWipeRing && MotionScope.enabledOf(context)) {
      _wipe.forward(from: 0).whenComplete(() {
        if (mounted) setState(() => _copied = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = SetupColors.isDark(context);
    final ok = AppFamilies.emerald;
    final text = SetupColors.text(context);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: (dark ? Colors.white : AppFamilies.sky.base).withValues(alpha: dark ? 0.05 : 0.06),
          borderRadius: BorderRadius.circular(AppRadius.r16),
          border: Border.all(color: SetupColors.border(context)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.label,
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: SetupColors.muted(context)),
                    ),
                    const SizedBox(height: 2),
                    // Tek satır: değer (PIN/anahtar) tireden ya da harf ortasından BÖLÜNMEZ; dar yerde/büyük yazıda sığacak kadar
                    // küçülür (FittedBox). Metin seçilemez `Text` kalır (kopyalama yalnız düğmeyle; bkz. sınıf belgesi).
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(
                        widget.shown,
                        maxLines: 1,
                        softWrap: false,
                        style: TextStyle(
                          // Kısa değerler (PIN) büyük; uzun değerler (cihaz anahtarı) daha küçük başlar.
                          fontSize: widget.shown.length > 14 ? 17 : AppText.metric,
                          height: 1.2,
                          fontWeight: FontWeight.w800,
                          letterSpacing: widget.shown.length > 14 ? 0.6 : 2,
                          fontFeatures: const [FontFeature.tabularFigures()],
                          color: text,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              SizedBox.square(
                dimension: 56,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (_copied && widget.showWipeRing)
                      Semantics(
                        liveRegion: true,
                        label: 'Panoya kopyalandı; ${SecretClipboard.defaultWipeAfter.inSeconds} saniye sonra silinir',
                        child: RepaintBoundary(
                          child: CustomPaint(
                            size: const Size.square(56),
                            painter: _WipeRingPainter(
                              progress: _wipe,
                              active: MotionScope.enabledOf(context),
                              // Açık temada halka koyu aile tonudur (ham emerald.base kartta ≈ 2.3:1'di).
                              color: AppTheme.accentTone(context, ok).withValues(alpha: 1),
                              track: AppTheme.accentTone(context, ok).withValues(alpha: 0.28),
                            ),
                          ),
                        ),
                      ),
                    GlassIconButton(
                      key: widget.copyKey,
                      icon: _copied ? Icons.check_rounded : Icons.copy_rounded,
                      iconColor: _copied ? SetupColors.readable(context, ok.base) : null,
                      semanticLabel: '${widget.label} kopyala',
                      haptic: PressHaptic.light,
                      onTap: _onCopy,
                    ),
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

/// Silme halkası: dolu başlar, [progress] ilerledikçe saat yönünde boşalır (`active` değilse tam dolu iz).
class _WipeRingPainter extends CustomPainter {
  _WipeRingPainter({required this.progress, required this.active, required this.color, required this.track})
    : super(repaint: progress);

  final Animation<double> progress;
  final bool active;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 3.0;
    final rect = (Offset.zero & size).deflate(stroke / 2);
    canvas.drawArc(rect, 0, math.pi * 2, false, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = track);
    final remaining = active ? 1.0 - progress.value : 1.0;
    if (remaining <= 0) return;
    canvas.drawArc(
      rect,
      -math.pi / 2,
      math.pi * 2 * remaining,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_WipeRingPainter old) =>
      old.progress != progress || old.active != active || old.color != color || old.track != track;
}
