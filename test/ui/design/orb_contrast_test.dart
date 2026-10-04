import 'dart:ui' as ui;

import 'package:ev_otomasyon/ui/theme/tokens.dart';
import 'package:ev_otomasyon/ui/widgets/orb/orb.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Orb gövdesi üzerindeki simge rengi ≥ 3:1 (WCAG UI bileşeni/büyük metin) — yalnız formülle DEĞİL, gövdenin
/// GERÇEK çizilen pikselleriyle (speküler, alt gölge, yansıma dahil) doğrulanır.
void main() {
  const d = 128.0;

  /// Simge kutusu (0.44 d, merkezde) içindeki 5×5 ızgaradan gerçek piksel renkleri.
  Future<List<Color>> glyphAreaPixels(WidgetTester tester, OrbColors colors) async {
    final rgba = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      paintOrbBody(canvas, const Offset(d / 2, d / 2), d / 2, colors);
      final image = await recorder.endRecording().toImage(d.toInt(), d.toInt());
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return data!;
    });
    final out = <Color>[];
    const half = 0.22 * d;
    for (var iy = 0; iy < 5; iy++) {
      for (var ix = 0; ix < 5; ix++) {
        final x = (d / 2 - half + (2 * half) * ix / 4).round().clamp(0, d.toInt() - 1);
        final y = (d / 2 - half + (2 * half) * iy / 4).round().clamp(0, d.toInt() - 1);
        final o = (y * d.toInt() + x) * 4;
        final a = rgba!.getUint8(o + 3);
        expect(a, 255, reason: 'simge alanı gövde içinde olmalı');
        out.add(Color.fromARGB(255, rgba.getUint8(o), rgba.getUint8(o + 1), rgba.getUint8(o + 2)));
      }
    }
    return out;
  }

  group('aile orb\'ları: simge ≥ 3:1', () {
    for (final family in AppFamilies.all) {
      testWidgets('${family.name}: simge rengi gövdenin gerçek pikselleri üzerinde ≥ 3:1', (tester) async {
        final colors = OrbColors.family(family);
        final pixels = await glyphAreaPixels(tester, colors);
        var worst = double.infinity;
        for (final p in pixels) {
          final r = wcagContrast(colors.icon, p);
          if (r < worst) worst = r;
        }
        expect(worst, greaterThanOrEqualTo(3.0), reason: '${family.name}: en kötü kontrast ${worst.toStringAsFixed(2)}');
      });

      test('${family.name}: formül örnekleri (merkez/taban/açık) ≥ 3:1 ve beyaz ya da koyu mürekkep', () {
        final icon = OrbColors.family(family).icon;
        expect(icon == Colors.white || icon == OrbColors.inkFor(family), isTrue);
        for (final body in [Color.lerp(family.light, family.base, 0.49)!, family.base, Color.lerp(family.light, family.base, 0.25)!]) {
          expect(wcagContrast(icon, body), greaterThanOrEqualTo(3.0), reason: family.name);
        }
      });
    }
  });

  for (final brightness in [Brightness.dark, Brightness.light]) {
    testWidgets('cam (kapalı toggle) simgesi ${brightness.name} temada gerçek piksellerde ≥ 3:1', (tester) async {
      final colors = OrbColors.glass(brightness);
      final pixels = await glyphAreaPixels(tester, colors);
      for (final p in pixels) {
        expect(wcagContrast(colors.icon, p), greaterThanOrEqualTo(3.0));
      }
    });

    testWidgets('devre dışı simge + kenar ${brightness.name} temada ≥ 3:1', (tester) async {
      final colors = OrbColors.disabled(brightness);
      final pixels = await glyphAreaPixels(tester, colors);
      for (final p in pixels) {
        expect(wcagContrast(colors.icon, p), greaterThanOrEqualTo(3.0), reason: 'simge');
      }
      // Kenar (rim) yüzey üstünde ≥ 3:1: kartın en açık/en koyu ucuyla ölç.
      final t = SurfaceTokens.of(brightness);
      for (final surface in [t.cardTop, t.cardBottom]) {
        for (final rim in [colors.rimStart, colors.rimEnd]) {
          expect(wcagContrast(Color.alphaBlend(rim, surface), surface), greaterThanOrEqualTo(3.0), reason: 'devre dışı kenar / ${brightness.name}');
        }
      }
    });
  }

  test('beyaz/koyu mürekkep seçimi: seçilen, en kötü örnekte diğerinden iyidir', () {
    for (final f in AppFamilies.all) {
      final chosen = OrbColors.family(f).icon;
      final other = chosen == Colors.white ? OrbColors.inkFor(f) : Colors.white;
      double worst(Color c) => [Color.lerp(f.light, f.base, 0.49)!, f.base].map((b) => wcagContrast(c, b)).reduce((a, b) => a < b ? a : b);
      expect(worst(chosen), greaterThanOrEqualTo(worst(other)), reason: f.name);
    }
  });
}
