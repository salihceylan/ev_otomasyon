import 'package:ev_otomasyon/ui/motion/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'design_support.dart';

/// `Skeleton`/`SkeletonCard`: tek paylaşılan süpürme, 12 sn sonra durur, off'ta saat dinlenmez.
/// `PulseRing`: tek seferlik halka, off'ta hiçbir şey.
void main() {
  group('Skeleton', () {
    testWidgets('kapsam yok / off: saat DİNLENMEZ (Ticker kurulmaz), pumpAndSettle takılmaz', (tester) async {
      for (final mode in <MotionMode?>[null, MotionMode.off]) {
        final clock = AmbientClock();
        addTearDown(clock.dispose);
        await tester.pumpWidget(designHost(const Skeleton(width: 100, height: 14), mode: mode, clock: clock));
        expect(clock.isTicking, isFalse);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('disableAnimations: full kapsamda bile süpürme yok', (tester) async {
      final clock = AmbientClock();
      addTearDown(clock.dispose);
      await tester.pumpWidget(designHost(const Skeleton(width: 100), mode: MotionMode.full, clock: clock, disableAnimations: true));
      expect(clock.isTicking, isFalse);
    });

    testWidgets('full: paylaşılan saati dinler, TEK saat (birden çok iskelet tek Ticker)', (tester) async {
      final clock = AmbientClock();
      addTearDown(clock.dispose);
      await tester.pumpWidget(
        designHost(
          const Column(
            mainAxisSize: MainAxisSize.min,
            children: [Skeleton(width: 80), Skeleton(width: 80), SkeletonCard(), Skeleton.circle(size: 30)],
          ),
          mode: MotionMode.full,
          clock: clock,
        ),
      );
      expect(clock.isTicking, isTrue);
      await tester.pump(const Duration(milliseconds: 200));
      // Hepsi aynı saatten türer: ek Ticker yok (yalnız saatin kendisi).
      expect(tester.binding.transientCallbackCount, 1, reason: 'tek paylaşılan Ticker');
    });

    testWidgets('12 sn sonra süpürme DURUR: saat dinleyicisi bırakılır, kare istenmez', (tester) async {
      final clock = AmbientClock();
      addTearDown(clock.dispose);
      await tester.pumpWidget(designHost(const Skeleton(width: 80), mode: MotionMode.full, clock: clock));
      expect(clock.isTicking, isTrue);
      // 11 sn: hâlâ sürüyor.
      for (var i = 0; i < 11; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(clock.isTicking, isTrue);
      for (var i = 0; i < 2; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(clock.isTicking, isFalse, reason: '12 sn zaman aşımı');
      await tester.pump();
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpAndSettle(); // takılmaz
    });

    testWidgets('maxSweep özelleştirilebilir', (tester) async {
      final clock = AmbientClock();
      addTearDown(clock.dispose);
      await tester.pumpWidget(designHost(const Skeleton(width: 80, maxSweep: Duration(seconds: 2)), mode: MotionMode.full, clock: clock));
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(clock.isTicking, isFalse);
    });

    testWidgets('dispose: ağaçtan kalkınca saat durur', (tester) async {
      final clock = AmbientClock();
      addTearDown(clock.dispose);
      await tester.pumpWidget(designHost(const Skeleton(width: 80), mode: MotionMode.full, clock: clock));
      expect(clock.isTicking, isTrue);
      await tester.pumpWidget(designHost(const SizedBox(), mode: MotionMode.full, clock: clock));
      expect(clock.isTicking, isFalse);
    });

    testWidgets('sabit saat (golden): çizilir, saat çalışmaz, iskelet anlamsal ağaçta yok', (tester) async {
      final clock = AmbientClock.fixed(0.7);
      addTearDown(clock.dispose);
      await tester.pumpWidget(designHost(const SkeletonCard(), mode: MotionMode.full, clock: clock));
      expect(clock.isTicking, isFalse);
      expect(tester.takeException(), isNull);
      expect(find.descendant(of: find.byType(SkeletonCard), matching: find.byType(ExcludeSemantics)), findsWidgets);
    });

    testWidgets('SkeletonCard: yazı ölçeği 2.0 ve dar ekranda taşmaz; sabit yükseklik yok', (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(designHost(const SkeletonCard(lines: 3), textScale: 2.0, center: false, mode: MotionMode.off));
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(SkeletonCard)).width, 320);
    });
  });

  group('PulseRing', () {
    Widget ring(int trigger, {bool playOnMount = false}) => PulseRing(color: Colors.green, diameter: 40, trigger: trigger, playOnMount: playOnMount);

    testWidgets('off: trigger değişse de animasyon KURULMAZ', (tester) async {
      await tester.pumpWidget(designHost(ring(0)));
      await tester.pumpWidget(designHost(ring(1)));
      expect(tester.hasRunningAnimations, isFalse);
      await tester.pumpAndSettle();
    });

    testWidgets('full: trigger değişince BİR KEZ oynar (450 ms) ve biter; pumpAndSettle biter', (tester) async {
      await tester.pumpWidget(designHost(ring(0), mode: MotionMode.full));
      expect(tester.hasRunningAnimations, isFalse, reason: 'tetiklenmeden oynamaz');
      await tester.pumpWidget(designHost(ring(1), mode: MotionMode.full));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pump(const Duration(milliseconds: 360));
      expect(tester.hasRunningAnimations, isFalse, reason: '450 ms sonra biter, döngü yok');
      await tester.pumpAndSettle();
    });

    testWidgets('aynı trigger ile yeniden kurulunca tekrar oynamaz; yeni değerde yeniden oynar', (tester) async {
      await tester.pumpWidget(designHost(ring(0), mode: MotionMode.full));
      await tester.pumpWidget(designHost(ring(1), mode: MotionMode.full));
      await tester.pumpAndSettle();
      await tester.pumpWidget(designHost(ring(1), mode: MotionMode.full));
      expect(tester.hasRunningAnimations, isFalse);
      await tester.pumpWidget(designHost(ring(2), mode: MotionMode.full));
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pumpAndSettle();
    });

    testWidgets('playOnMount: bağlanınca oynar', (tester) async {
      await tester.pumpWidget(designHost(ring(0, playOnMount: true), mode: MotionMode.full));
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pumpAndSettle();
    });

    testWidgets('etkileşimi engellemez (IgnorePointer)', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        designHost(
          Stack(
            alignment: Alignment.center,
            children: [
              GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => taps++, child: const SizedBox(width: 40, height: 40, key: Key('under'))),
              ring(1, playOnMount: true),
            ],
          ),
          mode: MotionMode.full,
        ),
      );
      await tester.tap(find.byKey(const Key('under')));
      expect(taps, 1);
      await tester.pumpAndSettle();
    });
  });
}
