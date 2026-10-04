import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../orb/orb.dart';

/// Basılı tutarak onaylatan düğme (bilinçli eylem). [holdDuration] boyunca basılı tutulursa
/// [onConfirmed] **bir kez** çağrılır; erken bırakılırsa ilerleme sıfırlanır ve hiçbir şey olmaz.
///
/// Görünüm (Neon Glass): hap (stadium) cam yüzey + aile renkli kenar; basılı tutuldukça içeride aile gradyanlı
/// dolgu soldan sağa dolar (önünde ince parlak kenar çizgisi) ve soldaki orb rozetinin çevresinde ilerleme halkası
/// (0..1) tamamlanır. Etiket basılıyken de DEĞİŞMEZ (neyin onaylandığı bağlamı kaybolmaz); ilerleme dolgu +
/// halka ile iki kanaldan verilir. Yazı ölçeği büyüdüğünde etiket satıra sarar (sabit yükseklik yok).
///
/// **Okunurluk:** etiket her ilerleme noktasında ≥ 4.5:1 kalır. Renkli dolgu üstünde sabit renkli metin okunmaz hâle
/// geliyordu (koyuda amber etiket / dolgu ≈ 2.5-3.4:1). Etiket iki katmanda çizilir: dolgusuz bölgede aile tonunun okunur
/// rengi ([AppTheme.readableAccent]), dolu bölgede ([fillStyle]) dolguya göre seçilen beyaz ya da koyu mürekkep; iki
/// katman ilerleme kenarında bölünür ("silme" etkisi; dolgu yoğun kalır, ilerleme net görünür). İlerleme kenar çizgisi
/// 2 dp'dir (etiketi ortadan "kesmez").
///
/// **Geometri:** hap yüksekliği en az [minHeight] (64 dp): orb (44) + halka payı (5+5) hap çerçevesinden ≥ 3 dp içeride
/// durur (56 dp'de halka çerçeveye değip çift kenar gibi okunuyordu).
///
/// Ekran okuyucu kullanıcıları için standart "uzun bas" erişilebilirlik eylemi onayı tetikler.
/// Dokunma yüksekliği en az [minHeight] (64 dp; erişilebilirlik tabanı 48 dp'nin üstü) olur.
class HoldToConfirmButton extends StatefulWidget {
  const HoldToConfirmButton({
    super.key,
    required this.label,
    required this.onConfirmed,
    this.holdDuration = const Duration(milliseconds: 1200),
    this.family = AppFamilies.amber,
    this.icon = Icons.lock_open_rounded,
  });

  final String label;
  final VoidCallback onConfirmed;
  final Duration holdDuration;

  /// Anlamsal renk ailesi (varsayılan amber: çocuk kilidi / dikkat).
  final AccentFamily family;
  final IconData icon;

  /// Hap yüksekliği tabanı (dp). Orb 44 + halka payı 2x5 = 54 dp halka; hap çerçevesinin (1.5 dp, içeride) ≥ 3 dp
  /// uzağında kalması için en az 63 dp gerekir. 64 dp'de orb merkezi (sol dolgu 10 + 22) = yükseklik/2: halka hapın sol
  /// yarım dairesiyle eş merkezlidir ve her yanda 3.5 dp boşluk kalır (56 dp'de 1 dp'ydi: halka çerçeveye değiyordu).
  static const double minHeight = 64;

  /// Dolu bölgedeki etiket mürekkebi için koyu ton (beyazın karşıtı).
  static const Color _darkInk = Color(0xFF0B1120);

  /// İlerleme dolgusunun yoğunluğu ve dolu bölgedeki etiketin mürekkebi. Dolgu soldan sağa yoğunlaşır (sol uç sağ ucun
  /// yarısı); istenen yoğunluk koyuda `.52`, açıkta `.42`dir. Mürekkep, dolgunun sol ve sağ ucundaki zemine karşı
  /// kontrastı en yüksek olan (beyaz ya da koyu) tondur; hiçbir yoğunlukta ikisi de ≥ 4.6:1 vermiyorsa (orta parlaklıkta
  /// zemin) yoğunluk 0.02 adımlarla (en az 0.08) azaltılır. Zemin: en zor yüzey (koyuda kart, açıkta sayfa zemini;
  /// [AppTheme.readableAccentOn] ile aynı kural) + hapın aile tonu (`.10`/`.12`). Aile/tema bağımsız bir sözleşmedir.
  @visibleForTesting
  static ({double endAlpha, Color ink}) fillStyle({required AccentFamily family, required bool dark}) {
    final surface = dark ? AppTheme.cardDark : AppTheme.bgLight;
    final tinted = Color.alphaBlend(family.base.withValues(alpha: dark ? 0.10 : 0.12), surface);
    final wanted = dark ? 0.52 : 0.42;
    double worst(Color ink, double end) => math.min(
          AppTheme.contrastRatio(ink, Color.alphaBlend(family.base.withValues(alpha: end * 0.5), tinted)),
          AppTheme.contrastRatio(ink, Color.alphaBlend(family.base.withValues(alpha: end), tinted)),
        );
    var step = 0;
    var alpha = wanted;
    while (true) {
      final white = worst(Colors.white, alpha);
      final black = worst(_darkInk, alpha);
      final ink = white >= black ? Colors.white : _darkInk;
      // Ondalık birikimi için tamsayı adımı.
      if (math.max(white, black) >= 4.6 || alpha <= 0.08 + 1e-9) return (endAlpha: math.max(alpha, 0.08), ink: ink);
      step++;
      alpha = wanted - step * 0.02;
    }
  }

  @override
  State<HoldToConfirmButton> createState() => _HoldToConfirmButtonState();
}

class _HoldToConfirmButtonState extends State<HoldToConfirmButton> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: widget.holdDuration)
    ..addStatusListener(_onStatus);

  bool _fired = false;

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) _confirm();
  }

  void _confirm() {
    if (_fired) return;
    _fired = true;
    HapticFeedback.heavyImpact();
    widget.onConfirmed();
  }

  void _start() {
    if (_fired) return;
    HapticFeedback.selectionClick();
    _controller.forward(from: 0);
  }

  void _cancel() {
    if (_fired) return;
    _controller.animateBack(0, duration: const Duration(milliseconds: 180));
  }

  @override
  void dispose() {
    _controller.removeStatusListener(_onStatus);
    _controller.dispose();
    super.dispose();
  }

  /// Orb + boşluk + etiket satırı: dolgusuz ve dolu bölge katmanları AYNI yerleşimi kullanır (etiket piksel piksel aynı
  /// yerde; yalnız mürekkep rengi değişir).
  Widget _content({required Color labelColor, required Widget orb}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 22, 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          orb,
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              widget.label,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: labelColor),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final family = widget.family;
    final dark = AppTheme.isDark(context);
    final ink = AppTheme.readableAccent(context, family.base);
    final border = dark ? family.base.withValues(alpha: 0.70) : family.deep;
    final arcColor = dark ? family.light : family.deep;
    // Dolgu yoğunluğu ve dolu bölgedeki etiket mürekkebi (bkz. [fillStyle]); sol uç sağ ucun yarısıdır.
    final fill = HoldToConfirmButton.fillStyle(family: family, dark: dark);
    final fillEnd = fill.endAlpha;
    return Semantics(
      button: true,
      label: widget.label,
      hint: 'Basılı tutarak onaylayın',
      excludeSemantics: true,
      onLongPress: _confirm,
      child: Listener(
        onPointerDown: (_) => _start(),
        onPointerUp: (_) => _cancel(),
        onPointerCancel: (_) => _cancel(),
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final progress = _fired ? 1.0 : _controller.value;
            final holding = progress > 0 && !_fired;
            return RepaintBoundary(
              child: Transform.scale(
                scale: holding ? 0.985 : 1.0,
                child: DecoratedBox(
                  // Kenar çizgisi en üstte (dolgu üzerinden de net kalır).
                  position: DecorationPosition.foreground,
                  decoration: ShapeDecoration(shape: StadiumBorder(side: BorderSide(color: border, width: 1.5))),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    child: ColoredBox(
                      color: family.base.withValues(alpha: dark ? 0.10 : 0.12),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: HoldToConfirmButton.minHeight),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            // İlerleme dolgusu: aile gradyanı + önde parlak kenar çizgisi.
                            Positioned.fill(
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: FractionallySizedBox(
                                  widthFactor: progress.clamp(0.0, 1.0),
                                  heightFactor: 1,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        colors: [
                                          family.base.withValues(alpha: fillEnd * 0.5),
                                          family.base.withValues(alpha: fillEnd),
                                        ],
                                      ),
                                      // İnce (2 dp) ilerleme kenarı: 4 dp'lik çizgi etiketi sözcük ortasından kesiyordu.
                                      border: progress > 0 && progress < 1
                                          ? Border(
                                              right: BorderSide(
                                                color: (dark ? family.light : family.deep).withValues(alpha: 0.85),
                                                width: 2,
                                              ),
                                            )
                                          : null,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            // Orb rozet + dolan halka + etiket (dolgusuz bölgedeki okunur aile tonunda).
                            _content(
                              labelColor: ink,
                              orb: SizedBox.square(
                                dimension: OrbSize.sm.diameter,
                                child: Stack(
                                  clipBehavior: Clip.none,
                                  children: [
                                    OrbIconBadge(icon: widget.icon, family: family, active: holding),
                                    Positioned(
                                      left: -5,
                                      top: -5,
                                      right: -5,
                                      bottom: -5,
                                      child: CustomPaint(
                                        painter: _HoldRingPainter(
                                          progress: progress,
                                          color: arcColor,
                                          track: family.base.withValues(alpha: dark ? 0.30 : 0.28),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            // Dolu bölgedeki etiket: AYNI yerleşim (orb yerinde boş yer tutucu), dolguya göre seçilmiş
                            // mürekkep; yalnız ilerleme kenarının soluna kırpılır ("silme"). Anlam ağacına girmez.
                            if (progress > 0)
                              Positioned.fill(
                                child: ExcludeSemantics(
                                  child: IgnorePointer(
                                    child: ClipRect(
                                      clipper: _ProgressClipper(progress),
                                      child: Align(
                                        child: _content(
                                          labelColor: fill.ink,
                                          orb: SizedBox.square(dimension: OrbSize.sm.diameter),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// İlerleme kenarının solunu (dolu bölgeyi) bırakan kırpıcı: dolgu [FractionallySizedBox] ile aynı genişlik.
class _ProgressClipper extends CustomClipper<Rect> {
  const _ProgressClipper(this.progress);

  final double progress;

  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, size.width * progress.clamp(0.0, 1.0), size.height);

  @override
  bool shouldReclip(_ProgressClipper oldClipper) => oldClipper.progress != progress;
}

class _HoldRingPainter extends CustomPainter {
  const _HoldRingPainter({required this.progress, required this.color, required this.track});

  final double progress;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 3.0;
    final rect = (Offset.zero & size).deflate(stroke / 2);
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = track;
    canvas.drawArc(rect, 0, math.pi * 2, false, base);
    if (progress <= 0) return;
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = color;
    canvas.drawArc(rect, -math.pi / 2, math.pi * 2 * progress.clamp(0.0, 1.0), false, arc);
  }

  @override
  bool shouldRepaint(_HoldRingPainter old) => old.progress != progress || old.color != color || old.track != track;
}
