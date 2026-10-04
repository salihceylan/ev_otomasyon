import 'package:ev_otomasyon/ui/motion/ambient_clock.dart';
import 'package:ev_otomasyon/ui/motion/motion_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'design_support.dart';

/// `MotionScope`: kapsam yoksa OFF (mevcut testleri korur), `full` yalnız açıkça verilir,
/// sistem "animasyonları kaldır" her zaman OFF yapar.
void main() {
  late MotionMode seen;
  late bool enabled;
  late Duration duration;
  late AmbientClock clock;

  final probe = Builder(builder: (context) {
    seen = MotionScope.modeOf(context);
    enabled = MotionScope.enabledOf(context);
    duration = MotionScope.durationOf(context, const Duration(milliseconds: 300));
    clock = MotionScope.clockOf(context);
    return const SizedBox();
  });

  testWidgets('kapsam YOKSA kip off, süre sıfır, saat paylaşılan saattir (varsayılan)', (tester) async {
    await tester.pumpWidget(designHost(probe));
    expect(seen, MotionMode.off);
    expect(enabled, isFalse);
    expect(duration, Duration.zero);
    expect(clock, same(AmbientClock.shared));
  });

  testWidgets('MotionScope(full) kipi full yapar ve süreyi korur; verilen saat kullanılır', (tester) async {
    final fixed = AmbientClock.fixed(1.0);
    addTearDown(fixed.dispose);
    await tester.pumpWidget(designHost(probe, mode: MotionMode.full, clock: fixed));
    expect(seen, MotionMode.full);
    expect(enabled, isTrue);
    expect(duration, const Duration(milliseconds: 300));
    expect(clock, same(fixed));
  });

  testWidgets('MotionScope(off) açıkça verilince de off', (tester) async {
    await tester.pumpWidget(designHost(probe, mode: MotionMode.off));
    expect(seen, MotionMode.off);
    expect(duration, Duration.zero);
  });

  testWidgets('MediaQuery.disableAnimations açıkken full kapsam bile off gibi davranır', (tester) async {
    await tester.pumpWidget(designHost(probe, mode: MotionMode.full, disableAnimations: true));
    expect(seen, MotionMode.off);
    expect(enabled, isFalse);
    expect(duration, Duration.zero);
  });

  testWidgets('kip değişince bağımlı widget yeniden kurulur (off -> full)', (tester) async {
    await tester.pumpWidget(designHost(probe, mode: MotionMode.off));
    expect(seen, MotionMode.off);
    await tester.pumpWidget(designHost(probe, mode: MotionMode.full));
    expect(seen, MotionMode.full);
  });

  testWidgets('MotionScope MaterialApp\'in ÜSTÜNDE de çalışır (runApp sarmalayıcısı biçimi)', (tester) async {
    // designHost(mode: full) kapsamı MaterialApp'in üstüne koyar: main.dart ile aynı biçim.
    await tester.pumpWidget(designHost(probe, mode: MotionMode.full));
    expect(seen, MotionMode.full);
  });
}
