import 'package:flutter/material.dart';

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

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgAsset = isDark
        ? 'assets/images/ai_circuit_bg.jpg'
        : 'assets/images/ai_circuit_bg_light.jpg';

    return Stack(
      children: [
        // 0. Temel Koyu/Açık Zemin Rengi
        Positioned.fill(
          child: Container(
            color: isDark ? const Color(0xFF0B1120) : const Color(0xFFF8FAFC),
          ),
        ),

        // 1. Elektronik Devre & Yapay Zeka Temalı Arka Plan Görseli
        Positioned.fill(
          child: Image.asset(
            bgAsset,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
          ),
        ),

        // 2. Siber Gradyan & Karartma/Aydınlatma Katmanı
        Positioned.fill(
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: isDark
                    ? [
                        const Color(0xFF0B1120).withValues(alpha: 0.50),
                        const Color(0xFF0B1120).withValues(alpha: 0.70),
                        const Color(0xFF0B1120).withValues(alpha: 0.88),
                      ]
                    : [
                        const Color(0xFFF8FAFC).withValues(alpha: 0.30),
                        const Color(0xFFF8FAFC).withValues(alpha: 0.50),
                        const Color(0xFFF8FAFC).withValues(alpha: 0.70),
                      ],
                stops: const [0.0, 0.45, 1.0],
              ),
            ),
          ),
        ),

        // 3. Vektörel PCB Veri Yolları (Vurgu katmanı - saydam çizim)
        Positioned.fill(
          child: RepaintBoundary(
            child: CustomPaint(
              painter: CircuitBoardPainter(isDark: isDark),
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
    final traceOpacity = isDark ? 0.08 : 0.09;
    final chipOpacity = isDark ? 0.05 : 0.06;

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
      ..color = baseColor.withValues(alpha: traceOpacity * 1.3)
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

    // Üst bölge hatları
    _addTrace(path, [
      Offset(0, h * 0.04),
      Offset(w * 0.08, h * 0.04),
      Offset(w * 0.12, h * 0.08),
      Offset(w * 0.40, h * 0.08),
      Offset(w * 0.45, h * 0.03),
      Offset(w * 0.90, h * 0.03),
    ]);

    _addTrace(path, [
      Offset(w * 0.08 + 64, h * 0.08),
      Offset(w * 0.35, h * 0.08),
      Offset(w * 0.42, h * 0.15),
      Offset(w * 0.65, h * 0.15),
      Offset(w * 0.70, h * 0.10),
      Offset(w, h * 0.10),
    ]);

    // Orta bölge hatları
    _addTrace(path, [
      Offset(0, h * 0.24),
      Offset(w * 0.25, h * 0.24),
      Offset(w * 0.32, h * 0.31),
      Offset(w * 0.55, h * 0.31),
      Offset(w * 0.62, h * 0.38),
      Offset(w * 0.72, h * 0.38),
    ]);

    _addTrace(path, [
      Offset(w * 0.72 + 76, h * 0.32),
      Offset(w * 0.88, h * 0.32),
      Offset(w * 0.93, h * 0.37),
      Offset(w, h * 0.37),
    ]);

    _addTrace(path, [
      Offset(w * 0.72 + 38, h * 0.28 + 56),
      Offset(w * 0.72 + 38, h * 0.46),
      Offset(w * 0.64, h * 0.54),
      Offset(w * 0.35, h * 0.54),
      Offset(w * 0.28, h * 0.61),
      Offset(w * 0.12 + 35, h * 0.61),
      Offset(w * 0.12 + 35, h * 0.68),
    ]);

    // Alt bölge hatları
    _addTrace(path, [
      Offset(0, h * 0.52),
      Offset(w * 0.18, h * 0.52),
      Offset(w * 0.24, h * 0.58),
      Offset(w * 0.48, h * 0.58),
      Offset(w * 0.54, h * 0.64),
      Offset(w * 0.85, h * 0.64),
      Offset(w * 0.90, h * 0.69),
      Offset(w, h * 0.69),
    ]);

    _addTrace(path, [
      Offset(w * 0.12 + 70, h * 0.72),
      Offset(w * 0.36, h * 0.72),
      Offset(w * 0.44, h * 0.80),
      Offset(w * 0.68, h * 0.80),
    ]);

    _addTrace(path, [
      Offset(w * 0.68 + 80, h * 0.86),
      Offset(w * 0.88, h * 0.86),
      Offset(w * 0.94, h * 0.92),
      Offset(w, h * 0.92),
    ]);

    _addTrace(path, [
      Offset(0, h * 0.88),
      Offset(w * 0.20, h * 0.88),
      Offset(w * 0.26, h * 0.94),
      Offset(w * 0.65, h * 0.94),
      Offset(w * 0.70, h * 0.99),
      Offset(w * 0.90, h * 0.99),
    ]);

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
