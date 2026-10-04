import 'package:ev_otomasyon/ui/motion/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'design_support.dart';

/// `SharedAxisSwitcher` (hareket v3 §2.4, §3): sihirbaz adım geçişi. İleri (index artar) → gelen sağdan,
/// geri → soldan; ağaçta her an tek adım (`Key('setup_step_<n>')`); off kipinde anında.
void main() {
  Widget host(int index, {MotionMode? mode}) => designHost(
        SizedBox(
          width: 400,
          height: 200,
          child: SharedAxisSwitcher(
            index: index,
            child: SizedBox(key: Key('setup_step_$index'), width: 100, height: 40, child: Text('adım $index')),
          ),
        ),
        mode: mode,
      );

  Future<double> midDx(WidgetTester tester, int from, int to) async {
    await tester.pumpWidget(host(from, mode: MotionMode.full));
    await tester.pumpAndSettle();
    final rest = tester.getTopLeft(find.byKey(Key('setup_step_$from'))).dx;
    await tester.pumpWidget(host(to, mode: MotionMode.full));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.byKey(Key('setup_step_$from')), findsNothing, reason: 'eski adım hemen kalkar');
    expect(find.byKey(Key('setup_step_$to')), findsOneWidget);
    final dx = tester.getTopLeft(find.byKey(Key('setup_step_$to'))).dx - rest;
    await tester.pump(const Duration(milliseconds: 160));
    expect(tester.getTopLeft(find.byKey(Key('setup_step_$to'))).dx, rest, reason: '220 ms sonunda yerinde');
    await tester.pumpAndSettle();
    return dx;
  }

  testWidgets('ileri: gelen adım sağdan (+) kayar', (tester) async {
    expect(await midDx(tester, 1, 2), greaterThan(0.0));
  });

  testWidgets('geri: gelen adım soldan (-) kayar', (tester) async {
    expect(await midDx(tester, 3, 2), lessThan(0.0));
  });

  testWidgets('off: anında, tek adım, animasyon yok', (tester) async {
    await tester.pumpWidget(host(1, mode: MotionMode.off));
    await tester.pumpWidget(host(2, mode: MotionMode.off));
    await tester.pump();
    expect(find.byKey(const Key('setup_step_1')), findsNothing);
    expect(find.byKey(const Key('setup_step_2')), findsOneWidget);
    expect(effectiveOpacity(tester, find.text('adım 2')), 1.0);
    expect(tester.hasRunningAnimations, isFalse);
    await tester.pumpAndSettle();
  });

  testWidgets('kapsam yok (testlerin varsayılanı): anında', (tester) async {
    await tester.pumpWidget(host(2));
    await tester.pumpWidget(host(1));
    await tester.pump();
    expect(find.byKey(const Key('setup_step_1')), findsOneWidget);
    expect(find.byKey(const Key('setup_step_2')), findsNothing);
    expect(tester.hasRunningAnimations, isFalse);
  });
}
