import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../motion/ambient_clock.dart';
import '../motion/motion_scope.dart';

/// AHBU Akıllı Ev & Bina Otomasyonu
/// Siber-Elektronik Devre Kartı (PCB Traces, Vias & Microchips) Arka Plan Çizicisi.
///
/// Logodaki elektronik kimliği yansıtır; PCB veri hatları, 45° açılı hatlar,
/// via lehim noktaları ve mikroçip silüetleri çizer.
/// Opasite çok düşüktür (%3-%5), odaklanılması gereken içeriği asla ezmez.
class CircuitBackground extends StatelessWidget {
  final Widget child;

  const CircuitBackground({
    super.key,
    required this.child,
  });

  /// Fotoğraf örtüsünün üst / orta (%45) / alt alfa durakları. Koyuda zemin `#0B1120`, açıkta `#F8FAFC` rengindedir.
  static const List<double> darkScrim = <double>[0.56, 0.74, 0.90];
  static const List<double> lightScrim = <double>[0.66, 0.76, 0.88];

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgAsset = isDark
        ? 'assets/images/ai_circuit_bg.jpg'
        : 'assets/images/ai_circuit_bg_light.jpg';

    return Stack(
      children: [
        // 0-2. Statik katmanlar (düz zemin + görsel + gradyan) TEK yeniden-çizim sınırında: bu üç tam ekran katman
        // yalnız tema değişince/boyut değişince yeniden kaydedilir; üstündeki içeriğin (sayfa, gösterge, geçiş)
        // yeniden boyanması bunları yeniden boyatmaz. Görsel, açılış ve giriş ekranlarıyla AYNI yol ve çözümleme
        // boyutu verilmeden yüklenir: koyu temada tek ImageCache girdisi paylaşılır (farklı boyut = çift çözümleme).
        Positioned.fill(
          child: RepaintBoundary(
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 0. Temel Koyu/Açık Zemin Rengi
                Container(
                  color: isDark ? const Color(0xFF0B1120) : const Color(0xFFF8FAFC),
                ),

                // 1. Elektronik Devre & Yapay Zeka Temalı Arka Plan Görseli
                Image.asset(
                  bgAsset,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
                ),

                // 2. Siber Gradyan & Karartma/Aydınlatma Katmanı (örtü). Zeminde DOĞRUDAN duran metinler (AppBar başlığı,
                // bölüm başlıkları, boş-durum yazıları, kayıt/şifre ekranı alt başlıkları) PCB fotoğrafının izleriyle
                // kesişmesin diye örtü yeterince yoğundur ([lightScrim]/[darkScrim]; açıkta eskiden .30/.50/.70'ti ve
                // metin izlerle/çip yazılarıyla iç içe geçiyordu).
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        for (final alpha in isDark ? darkScrim : lightScrim)
                          (isDark ? const Color(0xFF0B1120) : const Color(0xFFF8FAFC)).withValues(alpha: alpha),
                      ],
                      stops: const [0.0, 0.45, 1.0],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        // 3. Vektörel PCB Veri Yolları (Vurgu katmanı - saydam çizim; kendi sınırında)
        Positioned.fill(
          child: RepaintBoundary(
            child: CustomPaint(
              painter: CircuitBoardPainter(isDark: isDark),
            ),
          ),
        ),

        // 3b. Ambient 'veri nabzı': yalnız MotionScope full'de (+ AmbientClock: ön planda) birkaç parlak nokta mevcut
        // iz yollarında akar. Kendi RepaintBoundary'sinde küçük painter; statik katmanlar yeniden çizilmez.
        if (MotionScope.enabledOf(context))
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: DataPulsePainter(clock: MotionScope.clockOf(context), isDark: isDark),
                ),
              ),
            ),
          ),

        // 4. Sayfa İçeriği
        child,
      ],
    );
  }
}

class CircuitBoardPainter extends CustomPainter {
  final bool isDark;

  const CircuitBoardPainter({required this.isDark});

  @override
  void paint(Canvas canvas, Size size) {
    // 0. Saydam katman (Arka plan görselini örtmeyecek şekilde)
    // Renk ve opasite: Koyu modda siber cyan, açık modda canlı mavi
    final baseColor = isDark ? const Color(0xFF38BDF8) : const Color(0xFF0284C7);
    // Açık temada daha hafif: çip gövdeleri/kenarları kartların kenarından yarım dikdörtgen ("hayalet çip") olarak
    // seçiliyordu (eskiden gövde alfası .06, çip kenarı ≈ .117, iz .09). Açıkta çip yalnız belli belirsiz bir imza:
    // gövde .015, kenar .05, iz .075; koyu temada değişmedi.
    final traceOpacity = isDark ? 0.08 : 0.075;
    final chipOpacity = isDark ? 0.05 : 0.015;
    final chipBorderOpacity = isDark ? traceOpacity * 1.3 : 0.05;

    final tracePaint = Paint()
      ..color = baseColor.withValues(alpha: traceOpacity)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final viaPaint = Paint()
      ..color = baseColor.withValues(alpha: traceOpacity * 1.5)
      ..style = PaintingStyle.fill;

    final viaHolePaint = Paint()
      ..color = isDark ? const Color(0xFF0B1120) : const Color(0xFFF8FAFC)
      ..style = PaintingStyle.fill;

    final chipBodyPaint = Paint()
      ..color = baseColor.withValues(alpha: chipOpacity)
      ..style = PaintingStyle.fill;

    final chipBorderPaint = Paint()
      ..color = baseColor.withValues(alpha: chipBorderOpacity)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    final w = size.width;
    final h = size.height;

    // 1. MİKROÇİPLER (ICs) & Pin Bacakları
    // Sol üst çip: AHBU-MCU
    _drawMicrochip(
      canvas: canvas,
      rect: Rect.fromLTWH(w * 0.08, h * 0.06, 64, 48),
      pinsTopBottom: 5,
      pinsLeftRight: 4,
      bodyPaint: chipBodyPaint,
      borderPaint: chipBorderPaint,
      tracePaint: tracePaint,
    );

    // Sağ orta çip: ESP32-S3 Core
    _drawMicrochip(
      canvas: canvas,
      rect: Rect.fromLTWH(w * 0.72, h * 0.28, 76, 56),
      pinsTopBottom: 6,
      pinsLeftRight: 5,
      bodyPaint: chipBodyPaint,
      borderPaint: chipBorderPaint,
      tracePaint: tracePaint,
    );

    // Sol alt çip: RS485 / MODBUS Bus Controller
    _drawMicrochip(
      canvas: canvas,
      rect: Rect.fromLTWH(w * 0.12, h * 0.68, 70, 50),
      pinsTopBottom: 5,
      pinsLeftRight: 4,
      bodyPaint: chipBodyPaint,
      borderPaint: chipBorderPaint,
      tracePaint: tracePaint,
    );

    // Sağ alt çip: RELAY-BUS
    _drawMicrochip(
      canvas: canvas,
      rect: Rect.fromLTWH(w * 0.68, h * 0.82, 80, 52),
      pinsTopBottom: 6,
      pinsLeftRight: 4,
      bodyPaint: chipBodyPaint,
      borderPaint: chipBorderPaint,
      tracePaint: tracePaint,
    );

    // 2. PCB DEVRE VE VERİ YOLLARI (Traces with 45° angles and Vias)
    final path = Path();
    for (final trace in circuitTraces(size)) {
      _addTrace(path, trace);
    }

    // Hatları çiz
    canvas.drawPath(path, tracePaint);

    // 3. VIA LEHİM NOKTALARI (Test & Bağlantı Padleri)
    final vias = [
      Offset(w * 0.12, h * 0.08),
      Offset(w * 0.40, h * 0.08),
      Offset(w * 0.90, h * 0.03),
      Offset(w * 0.35, h * 0.08),
      Offset(w * 0.65, h * 0.15),
      Offset(w * 0.25, h * 0.24),
      Offset(w * 0.55, h * 0.31),
      Offset(w * 0.88, h * 0.32),
      Offset(w * 0.64, h * 0.54),
      Offset(w * 0.35, h * 0.54),
      Offset(w * 0.18, h * 0.52),
      Offset(w * 0.48, h * 0.58),
      Offset(w * 0.85, h * 0.64),
      Offset(w * 0.36, h * 0.72),
      Offset(w * 0.44, h * 0.80),
      Offset(w * 0.88, h * 0.86),
      Offset(w * 0.20, h * 0.88),
      Offset(w * 0.65, h * 0.94),
    ];

    for (final via in vias) {
      canvas.drawCircle(via, 3.2, viaPaint);
      canvas.drawCircle(via, 1.4, viaHolePaint);
    }
  }

  /// Devre izi yolları (45° açılı çok parçalı çizgiler): statik çizici ve ambient 'veri nabzı' katmanı AYNI
  /// yolları kullanır (nabız noktaları mevcut izler üzerinde akar).
  static List<List<Offset>> circuitTraces(Size size) {
    final w = size.width;
    final h = size.height;
    return <List<Offset>>[
      // Üst bölge hatları
      [
        Offset(0, h * 0.04),
        Offset(w * 0.08, h * 0.04),
        Offset(w * 0.12, h * 0.08),
        Offset(w * 0.40, h * 0.08),
        Offset(w * 0.45, h * 0.03),
        Offset(w * 0.90, h * 0.03),
      ],

      [
        Offset(w * 0.08 + 64, h * 0.08),
        Offset(w * 0.35, h * 0.08),
        Offset(w * 0.42, h * 0.15),
        Offset(w * 0.65, h * 0.15),
        Offset(w * 0.70, h * 0.10),
        Offset(w, h * 0.10),
      ],

      // Orta bölge hatları
      [
        Offset(0, h * 0.24),
        Offset(w * 0.25, h * 0.24),
        Offset(w * 0.32, h * 0.31),
        Offset(w * 0.55, h * 0.31),
        Offset(w * 0.62, h * 0.38),
        Offset(w * 0.72, h * 0.38),
      ],

      [
        Offset(w * 0.72 + 76, h * 0.32),
        Offset(w * 0.88, h * 0.32),
        Offset(w * 0.93, h * 0.37),
        Offset(w, h * 0.37),
      ],

      [
        Offset(w * 0.72 + 38, h * 0.28 + 56),
        Offset(w * 0.72 + 38, h * 0.46),
        Offset(w * 0.64, h * 0.54),
        Offset(w * 0.35, h * 0.54),
        Offset(w * 0.28, h * 0.61),
        Offset(w * 0.12 + 35, h * 0.61),
        Offset(w * 0.12 + 35, h * 0.68),
      ],

      // Alt bölge hatları
      [
        Offset(0, h * 0.52),
        Offset(w * 0.18, h * 0.52),
        Offset(w * 0.24, h * 0.58),
        Offset(w * 0.48, h * 0.58),
        Offset(w * 0.54, h * 0.64),
        Offset(w * 0.85, h * 0.64),
        Offset(w * 0.90, h * 0.69),
        Offset(w, h * 0.69),
      ],

      [
        Offset(w * 0.12 + 70, h * 0.72),
        Offset(w * 0.36, h * 0.72),
        Offset(w * 0.44, h * 0.80),
        Offset(w * 0.68, h * 0.80),
      ],

      [
        Offset(w * 0.68 + 80, h * 0.86),
        Offset(w * 0.88, h * 0.86),
        Offset(w * 0.94, h * 0.92),
        Offset(w, h * 0.92),
      ],

      [
        Offset(0, h * 0.88),
        Offset(w * 0.20, h * 0.88),
        Offset(w * 0.26, h * 0.94),
        Offset(w * 0.65, h * 0.94),
        Offset(w * 0.70, h * 0.99),
        Offset(w * 0.90, h * 0.99),
      ],
    ];
  }

  void _addTrace(Path path, List<Offset> points) {
    if (points.isEmpty) return;
    path.moveTo(points.first.dx, points.first.dy);
    for (int i = 1; i < points.length; i++) {
      path.lineTo(points[i].dx, points[i].dy);
    }
  }

  void _drawMicrochip({
    required Canvas canvas,
    required Rect rect,
    required int pinsTopBottom,
    required int pinsLeftRight,
    required Paint bodyPaint,
    required Paint borderPaint,
    required Paint tracePaint,
  }) {
    // Çip Gövdesi (QFP / SOP Paketi)
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(4));
    canvas.drawRRect(rrect, bodyPaint);
    canvas.drawRRect(rrect, borderPaint);

    // Çip pin-1 index çentiği (sol üstteki minik nokta)
    final dotPaint = Paint()
      ..color = borderPaint.color
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(rect.left + 7, rect.top + 7), 2.0, dotPaint);

    // Üst ve Alt Bacaklar (Pins)
    final pinLength = 5.0;
    final topStep = rect.width / (pinsTopBottom + 1);
    for (int i = 1; i <= pinsTopBottom; i++) {
      final x = rect.left + topStep * i;
      // Üst pin
      canvas.drawLine(Offset(x, rect.top), Offset(x, rect.top - pinLength), tracePaint);
      // Alt pin
      canvas.drawLine(Offset(x, rect.bottom), Offset(x, rect.bottom + pinLength), tracePaint);
    }

    // Sol ve Sağ Bacaklar (Pins)
    final sideStep = rect.height / (pinsLeftRight + 1);
    for (int i = 1; i <= pinsLeftRight; i++) {
      final y = rect.top + sideStep * i;
      // Sol pin
      canvas.drawLine(Offset(rect.left, y), Offset(rect.left - pinLength, y), tracePaint);
      // Sağ pin
      canvas.drawLine(Offset(rect.right, y), Offset(rect.right + pinLength, y), tracePaint);
    }
  }

  @override
  bool shouldRepaint(covariant CircuitBoardPainter oldDelegate) {
    return oldDelegate.isDark != isDark;
  }
}

/// Devre izlerinde akan **en çok 6** parlak "veri nabzı" noktası (ambient; `MotionMode.full` + [AmbientClock]).
///
/// * Tek zaman kaynağı paylaşılan [AmbientClock]'tur (kendi `Ticker`'ı yok; dinleyici = bu painter, ön planda
///   değilken/`fixed` iken saat ilerlemez). `MaskFilter.blur`/`saveLayer`/`Opacity` YOK: nokta, alfası azalan
///   eşmerkezli daireler + kısa iz kuyruğudur.
/// * Noktalar [CircuitBoardPainter.circuitTraces] yollarında ilerler; her nokta yolunu bitirince kısa bir
///   sönük bekleyişle başa döner. Konum yalnız saatten türer (durumsuz, deterministik: golden için
///   `AmbientClock.fixed`).
class DataPulsePainter extends CustomPainter {
  DataPulsePainter({required this.clock, required this.isDark}) : super(repaint: clock);

  final AmbientClock clock;
  final bool isDark;

  /// Üst sınır (ambient bütçesi: ≤ 6 nokta).
  static const int maxDots = 6;

  // (iz sırası, hız px/sn, başlangıç fazı 0..1, yön)
  static const List<(int, double, double, bool)> _dots = [
    (0, 96, 0.05, true),
    (1, 84, 0.45, true),
    (2, 110, 0.20, true),
    (4, 78, 0.70, true),
    (5, 92, 0.35, false),
    (7, 88, 0.85, true),
  ];

  Size? _cachedSize;
  List<List<Offset>> _traces = const [];
  List<List<double>> _cumulative = const [];

  void _prepare(Size size) {
    if (_cachedSize == size) return;
    _cachedSize = size;
    _traces = CircuitBoardPainter.circuitTraces(size);
    _cumulative = [
      for (final t in _traces)
        () {
          final acc = <double>[0];
          for (var i = 1; i < t.length; i++) {
            acc.add(acc.last + (t[i] - t[i - 1]).distance);
          }
          return acc;
        }(),
    ];
  }

  Offset _at(int trace, double d) {
    final pts = _traces[trace];
    final cum = _cumulative[trace];
    final clamped = d.clamp(0.0, cum.last);
    var i = 1;
    while (i < cum.length - 1 && cum[i] < clamped) {
      i++;
    }
    final seg = cum[i] - cum[i - 1];
    final f = seg <= 0 ? 0.0 : (clamped - cum[i - 1]) / seg;
    return Offset.lerp(pts[i - 1], pts[i], f)!;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    _prepare(size);
    final t = clock.time;
    final base = isDark ? const Color(0xFF38BDF8) : const Color(0xFF0284C7);
    final gain = isDark ? 1.0 : 0.8;
    final paint = Paint()..style = PaintingStyle.fill;
    final count = math.min(maxDots, _dots.length);
    for (var n = 0; n < count; n++) {
      final (trace, speed, phase, forward) = _dots[n];
      if (trace >= _traces.length) continue;
      final length = _cumulative[trace].last;
      if (length <= 0) continue;
      // Yol + sönük bekleyiş (0.5 yol uzunluğu) kadar bir döngü; bekleyişte nokta çizilmez.
      final cycle = length * 1.5;
      final travelled = (t * speed + phase * cycle) % cycle;
      if (travelled > length) continue;
      final d = forward ? travelled : length - travelled;
      // Uçlara yaklaşırken sönme (yeni noktanın aniden belirmemesi için).
      final edge = math.min(travelled, length - travelled);
      final fade = (edge / 36).clamp(0.0, 1.0);

      // Kuyruk: gidilen yönün tersinde 4 sönük nokta.
      for (var k = 4; k >= 1; k--) {
        final dd = forward ? d - k * 7.0 : d + k * 7.0;
        if (dd < 0 || dd > length) continue;
        paint.color = base.withValues(alpha: 0.10 * gain * fade * (1 - k / 5));
        canvas.drawCircle(_at(trace, dd), 2.4 - k * 0.3, paint);
      }
      final head = _at(trace, d);
      paint.color = base.withValues(alpha: 0.07 * gain * fade);
      canvas.drawCircle(head, 10, paint);
      paint.color = base.withValues(alpha: 0.14 * gain * fade);
      canvas.drawCircle(head, 6, paint);
      paint.color = base.withValues(alpha: 0.38 * gain * fade);
      canvas.drawCircle(head, 3.4, paint);
      paint.color = (isDark ? Colors.white : const Color(0xFF0369A1)).withValues(alpha: 0.9 * fade);
      canvas.drawCircle(head, 1.6, paint);
    }
  }

  @override
  bool shouldRepaint(DataPulsePainter old) => old.clock != clock || old.isDark != isDark;
}
