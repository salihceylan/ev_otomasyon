import 'package:ev_otomasyon/ui/motion/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'design_support.dart';

/// `StaggeredEntrance`: Interval ile kademe (Timer/Future.delayed YOK), tek sefer, off'ta anında tam görünür.
void main() {
  Widget item(int i) => StaggeredEntrance(index: i, child: SizedBox(key: Key('i$i'), width: 40, height: 20));

  Widget list({MotionMode? mode, int count = 4}) => designHost(
        Column(mainAxisSize: MainAxisSize.min, children: [for (var i = 0; i < count; i++) item(i)]),
        mode: mode,
      );

  group('off', () {
    for (final mode in <MotionMode?>[null, MotionMode.off]) {
      testWidgets('kip ${mode ?? "kapsam yok"}: çocuk İLK karede tam opak ve yerinde; animasyon/zamanlayıcı yok', (tester) async {
        await tester.pumpWidget(list(mode: mode));
        for (var i = 0; i < 4; i++) {
          expect(effectiveOpacity(tester, find.byKey(Key('i$i'))), 1.0);
        }
        expect(tester.hasRunningAnimations, isFalse);
        await tester.pump();
        expect(tester.binding.hasScheduledFrame, isFalse);
        await tester.pumpAndSettle();
      });
    }

    testWidgets('disableAnimations: full kapsamda bile anında', (tester) async {
      await tester.pumpWidget(designHost(item(2), mode: MotionMode.full, disableAnimations: true));
      expect(effectiveOpacity(tester, find.byKey(const Key('i2'))), 1.0);
      expect(tester.hasRunningAnimations, isFalse);
    });
  });

  group('full', () {
    testWidgets('ilk karede gizli (opaklık 0), sonra belirir ve pumpAndSettle ile biter', (tester) async {
      await tester.pumpWidget(list(mode: MotionMode.full));
      expect(effectiveOpacity(tester, find.byKey(const Key('i0'))), 0.0);
      await tester.pump(const Duration(milliseconds: 100));
      final mid = effectiveOpacity(tester, find.byKey(const Key('i0')));
      expect(mid, inExclusiveRange(0.0, 1.0));
      await tester.pumpAndSettle();
      for (var i = 0; i < 4; i++) {
        expect(effectiveOpacity(tester, find.byKey(Key('i$i'))), 1.0);
      }
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('kademe: aynı anda önceki öğe sonrakinden daha belirgindir; hepsi ≤ 8 öğe kuralıyla biter', (tester) async {
      await tester.pumpWidget(list(mode: MotionMode.full, count: 6));
      await tester.pump(const Duration(milliseconds: 110));
      final o = [for (var i = 0; i < 6; i++) effectiveOpacity(tester, find.byKey(Key('i$i')))];
      for (var i = 1; i < 6; i++) {
        expect(o[i], lessThanOrEqualTo(o[i - 1]), reason: 'öğe $i, öğe ${i - 1}\'den sonra başlar: $o');
      }
      expect(o.first, greaterThan(o.last));
      // En geç: 5 × 40 ms gecikme + 220 ms = 420 ms.
      await tester.pump(const Duration(milliseconds: 330));
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('8. öğeden sonrakiler son öğeyle AYNI gecikmeyi alır (toplam süre sınırlı)', (tester) async {
      await tester.pumpWidget(designHost(
        Column(mainAxisSize: MainAxisSize.min, children: [item(7), item(50)]),
        mode: MotionMode.full,
      ));
      await tester.pump(const Duration(milliseconds: 150));
      expect(
        effectiveOpacity(tester, find.byKey(const Key('i7'))),
        closeTo(effectiveOpacity(tester, find.byKey(const Key('i50'))), 1e-9),
      );
      await tester.pump(AppMotion.staggerStep * (AppMotion.staggerMaxItems - 1) + AppMotion.base);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('Timer/Future.delayed YOK: bekleyen zamanlayıcı bırakmaz (test sonu denetimi) ve girdiyi bloklamaz', (tester) async {
      var taps = 0;
      await tester.pumpWidget(designHost(
        StaggeredEntrance(index: 3, child: GestureDetector(key: const Key('tap'), behavior: HitTestBehavior.opaque, onTap: () => taps++, child: const SizedBox(width: 60, height: 60))),
        mode: MotionMode.full,
      ));
      // Giriş animasyonunun ORTASINDA bile dokunuş çalışır.
      await tester.pump(const Duration(milliseconds: 30));
      await tester.tap(find.byKey(const Key('tap')));
      expect(taps, 1);
      await tester.pumpAndSettle();
    });

    testWidgets('tek sefer: üst widget yeniden kurulunca animasyon yeniden başlamaz', (tester) async {
      await tester.pumpWidget(list(mode: MotionMode.full, count: 1));
      await tester.pumpAndSettle();
      await tester.pumpWidget(list(mode: MotionMode.full, count: 1));
      expect(effectiveOpacity(tester, find.byKey(const Key('i0'))), 1.0);
      expect(tester.hasRunningAnimations, isFalse);
    });
  });

  testWidgets('yukarı kayma: başlangıçta offset kadar aşağıda, sonunda 0', (tester) async {
    await tester.pumpWidget(designHost(StaggeredEntrance(index: 0, offset: 12, child: SizedBox(key: const Key('x'), width: 10, height: 10)), mode: MotionMode.full));
    final y0 = tester.getTopLeft(find.byKey(const Key('x'))).dy;
    await tester.pumpAndSettle();
    final y1 = tester.getTopLeft(find.byKey(const Key('x'))).dy;
    expect(y0 - y1, closeTo(12, 0.01));
  });
}
