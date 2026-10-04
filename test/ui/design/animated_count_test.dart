import 'package:ev_otomasyon/ui/motion/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'design_support.dart';

/// `AnimatedCount`: off kipinde ara değer YOK (anında son değer), full kipte akar ve biter, hedef kesilebilir,
/// ağaçta her an tek `Text`, anlamsal etiket yalnız son değer.
void main() {
  Widget count(int v, {String Function(int)? format}) => AnimatedCount(
        value: v,
        format: format,
        style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
      );

  group('off (kapsam yok / off / disableAnimations): ara değer YOK', () {
    final variants = <String, Widget Function(Widget)>{
      'kapsam yok': (c) => designHost(c),
      'MotionMode.off': (c) => designHost(c, mode: MotionMode.off),
      'disableAnimations': (c) => designHost(c, mode: MotionMode.full, disableAnimations: true),
    };
    for (final e in variants.entries) {
      testWidgets(e.key, (tester) async {
        await tester.pumpWidget(e.value(count(0, format: (v) => '%$v')));
        expect(find.text('%0'), findsOneWidget);
        await tester.pumpWidget(e.value(count(100, format: (v) => '%$v')));
        // pump ETMEDEN bile (tek kare) son değer; ara değerlerden hiçbiri hiç görünmez.
        expect(find.text('%100'), findsOneWidget, reason: 'anında son değer');
        expect(find.text('%0'), findsNothing);
        expect(tester.hasRunningAnimations, isFalse);
        await tester.pump();
        expect(tester.binding.hasScheduledFrame, isFalse);
        await tester.pumpAndSettle(); // takılmaz
        expect(find.text('%100'), findsOneWidget);
      });
    }

    testWidgets('birden çok art arda değişimde yalnız her seferki son değer görünür', (tester) async {
      final seen = <String>{};
      Widget build(int v) => designHost(Builder(builder: (context) {
            return AnimatedCount(value: v, style: const TextStyle(fontSize: 20));
          }));
      await tester.pumpWidget(build(0));
      for (final v in [10, 55, 100, 3]) {
        await tester.pumpWidget(build(v));
        seen.add(tester.widget<Text>(find.byType(Text)).data!);
      }
      expect(seen, {'10', '55', '100', '3'});
    });
  });

  group('full kip', () {
    testWidgets('ara değerler görünür, değer monoton artar ve pumpAndSettle ile son değerde biter', (tester) async {
      await tester.pumpWidget(designHost(count(0), mode: MotionMode.full));
      await tester.pumpWidget(designHost(count(100), mode: MotionMode.full));
      final values = <int>[];
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 30));
        values.add(int.parse(tester.widget<Text>(find.byType(Text)).data!));
        expect(find.byType(Text), findsOneWidget, reason: 'eski+yeni metin birlikte olmaz');
      }
      expect(values.first, greaterThan(0));
      expect(values.first, lessThan(100), reason: 'ara değer var');
      for (var i = 1; i < values.length; i++) {
        expect(values[i], greaterThanOrEqualTo(values[i - 1]), reason: 'monoton');
      }
      await tester.pumpAndSettle();
      expect(find.text('100'), findsOneWidget);
    });

    testWidgets('süre sınırı: slow (320 ms) içinde biter', (tester) async {
      await tester.pumpWidget(designHost(count(0), mode: MotionMode.full));
      await tester.pumpWidget(designHost(count(60), mode: MotionMode.full));
      await tester.pump(const Duration(milliseconds: 330));
      expect(find.text('60'), findsOneWidget);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('akış sürerken hedef değişirse GÖRÜNEN değerden yeni hedefe devam eder (kesilebilir)', (tester) async {
      await tester.pumpWidget(designHost(count(0), mode: MotionMode.full));
      await tester.pumpWidget(designHost(count(100), mode: MotionMode.full));
      await tester.pump(const Duration(milliseconds: 120));
      final mid = int.parse(tester.widget<Text>(find.byType(Text)).data!);
      expect(mid, inInclusiveRange(1, 99));
      await tester.pumpWidget(designHost(count(20), mode: MotionMode.full));
      final first = int.parse(tester.widget<Text>(find.byType(Text)).data!);
      expect((first - mid).abs(), lessThanOrEqualTo(2), reason: 'sıçrama yok: görünen değerden devam');
      await tester.pumpAndSettle();
      expect(find.text('20'), findsOneWidget);
    });

    testWidgets('aynı değer tekrar verilince animasyon başlamaz', (tester) async {
      await tester.pumpWidget(designHost(count(5), mode: MotionMode.full));
      await tester.pumpWidget(designHost(count(5), mode: MotionMode.full));
      expect(tester.hasRunningAnimations, isFalse);
    });
  });

  testWidgets('tabular rakamlar: genişlik titremesini önlemek için FontFeature.tabularFigures', (tester) async {
    await tester.pumpWidget(designHost(count(42)));
    final text = tester.widget<Text>(find.byType(Text));
    expect(text.style!.fontFeatures, contains(const FontFeature.tabularFigures()));
  });

  testWidgets('anlamsal etiket YALNIZ son değeri söyler (ara değerler okunmaz)', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(designHost(count(0, format: (v) => '%$v'), mode: MotionMode.full));
    await tester.pumpWidget(designHost(count(80, format: (v) => '%$v'), mode: MotionMode.full));
    await tester.pump(const Duration(milliseconds: 60));
    expect(tester.getSemantics(find.byType(AnimatedCount)).label, '%80');
    await tester.pumpAndSettle();
    handle.dispose();
  });

  testWidgets('dispose: akış sürerken ağaçtan kalkınca bekleyen animasyon kalmaz', (tester) async {
    await tester.pumpWidget(designHost(count(0), mode: MotionMode.full));
    await tester.pumpWidget(designHost(count(100), mode: MotionMode.full));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpWidget(designHost(const SizedBox()));
    expect(tester.hasRunningAnimations, isFalse);
  });
}
