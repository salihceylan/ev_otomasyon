import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../services/clock.dart';

/// Sunucudan gelen bekleme süresini (`resend_after` / `retry_after`) geri sayan küçük yardımcı.
///
/// Zaman kaynağı [Clock]'tur (`AutomationState.clock`): testlerde sahte saatle hızlı ilerletilir.
/// Kalan süre bitiş anına göre hesaplanır (zamanlayıcı kayması birikmez). [dispose] sonrası geri
/// çağrı çalışmaz.
///
/// **Yeniden kurulum maliyeti (PF-23):** geri çağrı [notifyOnTick] `true` (varsayılan, eski davranış) iken
/// HER SANİYE çağrılır; çağıran bunu genellikle `setState(() {})` yapar ve tüm diyaloğu saniyede bir kurar
/// (iki `Cooldown` = saniyede ~2 kez). [notifyOnTick] `false` ise geri çağrı YALNIZ kilit durumu değiştiğinde
/// (bekleme başladığında ve bittiğinde) çalışır: düğme kilidi gibi `isActive`'e bağlı yapı bu anlarda yeniden
/// kurulur. Saniye saniye değişen metin ise [remaining] dinlenerek yalnız o küçük `ValueListenableBuilder`
/// içinde güncellenir.
class Cooldown {
  Cooldown(this._clock, this._onChanged, {this.notifyOnTick = true});

  final Clock _clock;
  final void Function() _onChanged;

  /// `true` (varsayılan): her saniye geri çağrı. `false`: yalnız başlangıç ve bitişte (bkz. sınıf belgesi).
  final bool notifyOnTick;

  final ValueNotifier<int> _remaining = ValueNotifier<int>(0);
  Timer? _timer;
  DateTime? _deadline;
  bool _disposed = false;

  /// Kalan tam saniye (0 = bekleme yok / bitti).
  int get remainingSeconds {
    final deadline = _deadline;
    if (deadline == null) return 0;
    final ms = deadline.difference(_clock.now()).inMilliseconds;
    if (ms <= 0) return 0;
    return (ms / 1000).ceil();
  }

  bool get isActive => remainingSeconds > 0;

  /// Kalan tam saniye ([remainingSeconds]) değiştikçe haber verir (başlangıç, her tik, bitiş). Saniye saniye
  /// değişen metni yalnız küçük bir `ValueListenableBuilder`'da göstermek için ([notifyOnTick] `false` ile).
  ValueListenable<int> get remaining => _remaining;

  /// [duration] boyunca beklemeyi başlatır (önceki bekleme yerine geçer).
  void start(Duration duration) {
    if (_disposed) return;
    _timer?.cancel();
    if (duration <= Duration.zero) {
      _deadline = null;
      _timer = null;
      _remaining.value = 0;
      _onChanged();
      return;
    }
    _deadline = _clock.now().add(duration);
    _remaining.value = remainingSeconds;
    _timer = _clock.periodic(const Duration(seconds: 1), (timer) {
      if (_disposed) {
        timer.cancel();
        return;
      }
      final expired = !isActive;
      if (expired) {
        timer.cancel();
        _timer = null;
        _deadline = null;
      }
      _remaining.value = remainingSeconds;
      if (expired || notifyOnTick) _onChanged();
    });
    _onChanged();
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    _deadline = null;
    if (!_disposed) _remaining.value = 0;
  }

  void dispose() {
    _disposed = true;
    cancel();
    _remaining.dispose();
  }
}

/// Geri sayım kadranı (kronometre simgesi): [remaining] (bir [Cooldown.remaining]) saniye saniye azaldıkça
/// kadrandaki dolu dilim küçülür.
///
/// **Neden halka değil:** eski boş halka (yay), metin önünde "işaretlenmemiş radyo düğmesi" gibi okunuyordu.
/// Kadran bir halka + üstte düğme (kronometre) + dolu "kalan süre" dilimidir; açıkça bir zamanlayıcıdır.
///
/// Küçük, kendi `RepaintBoundary`'sinde ve yalnız saniyede bir yeniden çizilir (kendi `Ticker`'ı yok, sonsuz
/// animasyon değildir; `MotionMode`'dan bağımsız statik gösterge). Toplam süre, bekleme başladığında görülen en
/// büyük kalan değerdir ([total] verilirse o). Bekleme yokken (0 sn) hiçbir şey çizmez ama yerini korumaz:
/// [SizedBox.shrink]. Anlamdan hariçtir: kalan süre metni yanında zaten yazılıdır.
class CooldownArc extends StatefulWidget {
  const CooldownArc({super.key, required this.remaining, required this.color, this.total, this.size = 16, this.strokeWidth = 1.8});

  final ValueListenable<int> remaining;
  final Color color;

  /// Toplam süre (sn). Verilmezse ilk görülen kalan değer alınır.
  final int? total;
  final double size;

  /// Kadran halkasının çizgi kalınlığı (dp).
  final double strokeWidth;

  @override
  State<CooldownArc> createState() => _CooldownArcState();
}

class _CooldownArcState extends State<CooldownArc> {
  int _seen = 0;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: widget.remaining,
      builder: (context, seconds, _) {
        if (seconds <= 0) {
          _seen = 0;
          return const SizedBox.shrink();
        }
        if (seconds > _seen) _seen = seconds;
        final total = math.max(widget.total ?? _seen, seconds);
        return ExcludeSemantics(
          child: RepaintBoundary(
            child: SizedBox.square(
              dimension: widget.size,
              child: CustomPaint(
                painter: _CooldownArcPainter(fraction: seconds / total, color: widget.color, strokeWidth: widget.strokeWidth),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CooldownArcPainter extends CustomPainter {
  const _CooldownArcPainter({required this.fraction, required this.color, required this.strokeWidth});

  final double fraction;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final ring = math.min(strokeWidth, s * 0.14);
    // Kronometre: üstte küçük düğme, altında kadran halkası; halkanın içinde kalan süre dilimi (saat yönünde).
    final center = Offset(size.width / 2, size.height / 2 + s * 0.08);
    final radius = s * 0.42 - ring / 2;

    final nubWidth = s * 0.32;
    final nubHeight = math.max(ring, s * 0.1);
    final nub = RRect.fromRectAndRadius(
      Rect.fromLTWH((size.width - nubWidth) / 2, 0, nubWidth, nubHeight),
      Radius.circular(nubHeight / 2),
    );
    canvas.drawRRect(nub, Paint()..color = color);

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = ring
        ..color = color,
    );
    final wedge = Rect.fromCircle(center: center, radius: radius - ring * 1.1);
    canvas.drawArc(
      wedge,
      -math.pi / 2,
      math.pi * 2 * fraction.clamp(0.0, 1.0),
      true,
      Paint()
        ..style = PaintingStyle.fill
        ..color = color.withValues(alpha: 0.55),
    );
  }

  @override
  bool shouldRepaint(_CooldownArcPainter old) =>
      old.fraction != fraction || old.color != color || old.strokeWidth != strokeWidth;
}
