import 'package:flutter/material.dart';

import '../motion/motion_scope.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// Wi-Fi sinyal çubukları (4 çubuk): [level] çubuk dolu. Girişte çubuklar soldan sağa **sırayla dolar** (tek seferlik,
/// `base` süre; `MotionMode.off`: anında). Anlam: "Sinyal iyi/orta/zayıf" (renk tek ipucu değildir: çubuk sayısı +
/// ağ satırında dBm değeri yazılır).
///
/// RSSI -> çubuk: >= -55 dBm 4, >= -65 dBm 3, >= -75 dBm 2, daha zayıfı 1.
class WifiSignalBars extends StatefulWidget {
  const WifiSignalBars({super.key, required this.rssi, this.height = 18});

  final int rssi;
  final double height;

  /// RSSI'dan dolu çubuk sayısı (1..4).
  static int levelFor(int rssi) {
    if (rssi >= -55) return 4;
    if (rssi >= -65) return 3;
    if (rssi >= -75) return 2;
    return 1;
  }

  /// Erişilebilirlik etiketi ("iyi" / "orta" / "zayıf").
  static String labelFor(int rssi) {
    if (rssi >= -60) return 'iyi';
    if (rssi >= -75) return 'orta';
    return 'zayıf';
  }

  /// Bu widget'ın gösterdiği dolu çubuk sayısı.
  int get level => levelFor(rssi);

  @override
  State<WifiSignalBars> createState() => _WifiSignalBarsState();
}

class _WifiSignalBarsState extends State<WifiSignalBars> with SingleTickerProviderStateMixin {
  late final AnimationController _fill = AnimationController(vsync: this, duration: AppMotion.slow);
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MotionScope.enabledOf(context)) {
      _fill.forward(from: 0);
    } else {
      _fill.value = 1;
    }
  }

  @override
  void dispose() {
    _fill.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final level = widget.level;
    final AccentFamily family = level >= 3
        ? AppFamilies.emerald
        : (level == 2 ? AppFamilies.amber : AppFamilies.rose);
    final dark = AppTheme.isDark(context);
    // Açık temada ham aile tonu çubuk olarak 1.8-2.5:1'di (amber #FFB020 beyazda 1.83:1): koyu (deep) ton ≥ 3:1; koyu temada
    // ham ton zaten 5.8-8:1. İz açıkta biraz belirgin (0.30) ki boş çubuklar "kaybolmasın".
    final Color color = dark ? family.base : family.deep;
    // Boş (pasif) çubuklar pasif iz belirteciyle ≥ 3:1 (eskiden beyaz/slate alfa: açıkta 1.72:1, koyuda 1.66:1; kaç çubuğun
    // dolu olduğunu okumak için dBm metnine bakmak gerekiyordu).
    final track = AppTheme.getInactiveTrack(context);
    return Semantics(
      label: 'Sinyal ${WifiSignalBars.labelFor(widget.rssi)}',
      excludeSemantics: true,
      child: RepaintBoundary(
        child: CustomPaint(
          key: const Key('wifi_signal_bars'),
          size: Size(22, widget.height),
          painter: _BarsPainter(progress: _fill, level: level, color: color, track: track),
        ),
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  _BarsPainter({required this.progress, required this.level, required this.color, required this.track})
    : super(repaint: progress);

  final Animation<double> progress;
  final int level;
  final Color color;
  final Color track;

  static const int bars = 4;

  @override
  void paint(Canvas canvas, Size size) {
    const gap = 2.0;
    final barWidth = (size.width - gap * (bars - 1)) / bars;
    for (var i = 0; i < bars; i++) {
      final h = size.height * (0.38 + 0.62 * (i + 1) / bars);
      final left = i * (barWidth + gap);
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, size.height - h, barWidth, h),
        const Radius.circular(1.5),
      );
      canvas.drawRRect(rect, Paint()..color = track);
      if (i >= level) continue;
      // Çubuk i, toplam ilerlemenin [i/4 .. i/4 + 0.5] aralığında dolar (soldan sağa kademeli).
      final local = ((progress.value - i * 0.15) / 0.55).clamp(0.0, 1.0);
      if (local <= 0) continue;
      final filled = Rect.fromLTWH(left, size.height - h * local, barWidth, h * local);
      canvas.drawRRect(RRect.fromRectAndRadius(filled, const Radius.circular(1.5)), Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) =>
      old.progress != progress || old.level != level || old.color != color || old.track != track;
}
