import 'package:flutter/material.dart';

/// `OrbButton`/`OrbCore` için hazır `iconBuilder` simgeleri: orb içindeki simgelerin GÖRSEL AĞIRLIĞINI eşitler.
///
/// Material `Icons.arrow_upward_rounded` gibi ok simgeleri ince çizgidir (28 dp kutuda ≈ 2 dp); aynı orb setindeki
/// Durdur karesi, ampul, ay ve şimşek ise doludur: ok simgesi yanlarında zayıf kalır. Şartname §3.4 de dolu
/// ▲ ■ ▼ ister. Dolu yuvarlak üçgen için [triangle]; marka harfi gibi tek karakter için [letter].
///
/// ```dart
/// OrbButton(
///   icon: null,
///   iconBuilder: OrbIcons.triangle(up: true),
///   family: AppFamilies.emerald,
///   semanticLabel: 'Aç',
///   onTap: up,
/// )
/// ```
abstract final class OrbIcons {
  /// Orb simge gölgesi (`OrbCore` varsayılan simgesiyle aynı kural): açık simge → koyu gölge, koyu simge → açık gölge.
  static Color shadowFor(Color iconColor) =>
      iconColor.computeLuminance() > 0.5 ? const Color(0x4D000000) : const Color(0x47FFFFFF);

  /// Dolu, köşeleri yuvarlatılmış üçgen ok: [up] yukarı (panjur AÇ), aksi halde aşağı (panjur KAPAT).
  /// Üçgen, simge kutusunun (`size`) ≈ %92'sini kaplar; renk orb'un simge rengidir (gövde üstünde ≥ 3:1).
  static Widget Function(BuildContext context, Color color, double size) triangle({required bool up}) {
    return (context, color, size) => SizedBox.square(
          dimension: size,
          child: CustomPaint(painter: _TrianglePainter(color: color, up: up)),
        );
  }

  /// Tek karakterlik kalın simge (ör. Google için `G`): orb çapının ≈ 0.5'i yüksekliğinde, `w800`.
  static Widget Function(BuildContext context, Color color, double size) letter(String character) {
    return (context, color, size) => SizedBox.square(
          dimension: size,
          child: Center(
            child: Text(
              character,
              textScaler: TextScaler.noScaling,
              style: TextStyle(
                color: color,
                fontSize: size * 1.12,
                fontWeight: FontWeight.w800,
                height: 1.0,
                shadows: [Shadow(color: shadowFor(color), blurRadius: 2, offset: const Offset(0, 1))],
              ),
            ),
          ),
        );
  }
}

class _TrianglePainter extends CustomPainter {
  const _TrianglePainter({required this.color, required this.up});

  final Color color;
  final bool up;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final w = s * 0.86; // taban genişliği
    final h = s * 0.74; // yükseklik
    final r = s * 0.10; // köşe yuvarlama (kalın çizgi birleşimiyle)
    final cx = size.width / 2;
    final cy = size.height / 2;
    // Yukarı bakan üçgen: tepe üstte. Aşağı: dikeyde yansıt.
    final dir = up ? 1.0 : -1.0;
    final apex = Offset(cx, cy - dir * h / 2 + dir * r * 0.6);
    final left = Offset(cx - w / 2 + r, cy + dir * h / 2 - dir * r * 0.5);
    final right = Offset(cx + w / 2 - r, cy + dir * h / 2 - dir * r * 0.5);
    final path = Path()
      ..moveTo(apex.dx, apex.dy)
      ..lineTo(right.dx, right.dy)
      ..lineTo(left.dx, left.dy)
      ..close();

    // Yuvarlak köşe: dolgu + aynı renkte kalın, yuvarlak birleşimli çizgi.
    final fill = Paint()
      ..style = PaintingStyle.fill
      ..color = color;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = r * 2
      ..color = color;
    // Blur'suz ince gölge (OrbCore simge gölgesiyle aynı yön/ton).
    final shadow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = r * 2
      ..color = OrbIcons.shadowFor(color);
    canvas.drawPath(path.shift(const Offset(0, 1)), shadow);
    canvas.drawPath(path, stroke);
    canvas.drawPath(path, fill);
  }

  @override
  bool shouldRepaint(_TrianglePainter old) => old.color != color || old.up != up;
}
