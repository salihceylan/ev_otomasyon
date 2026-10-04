import 'package:ev_otomasyon/ui/motion/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'design_support.dart';

/// `Pressable`: pressed ölçeği parmak değdiği AN, `onTap` gecikmesiz, devre dışı dokunuş almaz,
/// kayma basılı durumu bırakır, release yaylanması yalnız full kipte ve biter, haptik tek çağrı.
void main() {
  const box = Key('box');
  Widget pressable({
    VoidCallback? onTap,
    bool enabled = true,
    PressHaptic haptic = PressHaptic.none,
    double overshoot = 1.0,
    VoidCallback? onLongPress,
  }) =>
      Pressable(
        onTap: onTap,
        onLongPress: onLongPress,
        enabled: enabled,
        haptic: haptic,
        pressedScale: 0.9,
        releaseOvershoot: overshoot,
        child: const SizedBox(key: box, width: 100, height: 100),
      );

  group('pressed ölçeği parmak değdiği AN uygulanır (tween yok)', () {
    for (final mode in <MotionMode?>[null, MotionMode.off, MotionMode.full]) {
      testWidgets('kip: ${mode ?? "kapsam yok"}', (tester) async {
        await tester.pumpWidget(designHost(pressable(onTap: () {}), mode: mode));
        final pressable0 = find.byType(Pressable);
        expect(pressableScale(tester, pressable0), 1.0);

        final g = await tester.startGesture(tester.getCenter(find.byKey(box)));
        await tester.pump(); // tek sıfır-süreli kare: animasyon ilerlemesi YOK
        expect(pressableScale(tester, pressable0), closeTo(0.9, 1e-9), reason: 'ilk karede tam basılı ölçek');
        await g.up();
        await tester.pumpAndSettle();
        expect(pressableScale(tester, pressable0), 1.0);
      });
    }
  });

  group('onTap gecikmesiz', () {
    testWidgets('parmak kalkar kalkmaz, hiçbir kare/zaman geçmeden çağrılır', (tester) async {
      var taps = 0;
      await tester.pumpWidget(designHost(pressable(onTap: () => taps++), mode: MotionMode.full));
      final g = await tester.startGesture(tester.getCenter(find.byKey(box)));
      await tester.pump();
      expect(taps, 0, reason: 'dokunuş sürerken çağrılmaz');
      await g.up();
      expect(taps, 1, reason: 'pointer-up ile EŞZAMANLI (pump/Duration beklenmeden)');
    });

    testWidgets('tester.tap tek karede (300 ms çift-dokunma bekleme penceresi YOK)', (tester) async {
      var taps = 0;
      await tester.pumpWidget(designHost(pressable(onTap: () => taps++, onLongPress: () {}), mode: MotionMode.full));
      await tester.tap(find.byKey(box));
      expect(taps, 1);
      await tester.pumpAndSettle();
      expect(taps, 1);
    });

    testWidgets('release yaylanması sürerken yeni dokunuş da anında çalışır (kuyruklama/blok yok)', (tester) async {
      var taps = 0;
      await tester.pumpWidget(designHost(pressable(onTap: () => taps++, overshoot: 1.05), mode: MotionMode.full));
      await tester.tap(find.byKey(box));
      await tester.pump(const Duration(milliseconds: 40)); // yaylanma ortasında
      expect(tester.hasRunningAnimations, isTrue);
      await tester.tap(find.byKey(box));
      expect(taps, 2);
      await tester.pumpAndSettle();
    });
  });

  group('devre dışı', () {
    testWidgets('onTap null: dokunuş etkisiz, ölçek değişmez', (tester) async {
      await tester.pumpWidget(designHost(pressable(), mode: MotionMode.full));
      final g = await tester.startGesture(tester.getCenter(find.byKey(box)));
      await tester.pump();
      expect(pressableScale(tester, find.byType(Pressable)), 1.0);
      await g.up();
      await tester.pumpAndSettle();
    });

    testWidgets('enabled=false: onTap çağrılmaz ve ölçek değişmez', (tester) async {
      var taps = 0;
      await tester.pumpWidget(designHost(pressable(onTap: () => taps++, enabled: false), mode: MotionMode.full));
      final g = await tester.startGesture(tester.getCenter(find.byKey(box)));
      await tester.pump();
      expect(pressableScale(tester, find.byType(Pressable)), 1.0);
      await g.up();
      expect(taps, 0);
    });

    testWidgets('basılıyken devre dışı kalırsa basılı durum bırakılır', (tester) async {
      var taps = 0;
      await tester.pumpWidget(designHost(pressable(onTap: () => taps++), mode: MotionMode.off));
      final g = await tester.startGesture(tester.getCenter(find.byKey(box)));
      await tester.pump();
      expect(pressableScale(tester, find.byType(Pressable)), closeTo(0.9, 1e-9));
      await tester.pumpWidget(designHost(pressable(onTap: () => taps++, enabled: false), mode: MotionMode.off));
      expect(pressableScale(tester, find.byType(Pressable)), 1.0);
      await g.up();
      expect(taps, 0);
    });
  });

  testWidgets('parmak kayarsa (kaydırma) basılı durum bırakılır ve onTap çağrılmaz', (tester) async {
    var taps = 0;
    await tester.pumpWidget(designHost(pressable(onTap: () => taps++), mode: MotionMode.off));
    final start = tester.getCenter(find.byKey(box));
    final g = await tester.startGesture(start);
    await tester.pump();
    expect(pressableScale(tester, find.byType(Pressable)), closeTo(0.9, 1e-9));
    await g.moveBy(const Offset(0, 60));
    await tester.pump();
    expect(pressableScale(tester, find.byType(Pressable)), 1.0, reason: 'kayma eşiği aşıldı');
    await g.up();
    expect(taps, 0, reason: 'sürükleme dokunma değildir');
  });

  group('release yaylanması', () {
    testWidgets('full: bırakınca ölçek 1.0 üstüne taşar (aşım) ve 1.0\'da biter; pumpAndSettle biter', (tester) async {
      await tester.pumpWidget(designHost(pressable(onTap: () {}, overshoot: 1.04), mode: MotionMode.full));
      final g = await tester.startGesture(tester.getCenter(find.byKey(box)));
      await tester.pump();
      await g.up();
      var maxScale = 0.0;
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        final s = pressableScale(tester, find.byType(Pressable));
        if (s > maxScale) maxScale = s;
      }
      expect(maxScale, greaterThan(1.02), reason: '1.0 → 1.04 → 1.0 yaylanması');
      expect(maxScale, lessThanOrEqualTo(1.0401));
      await tester.pumpAndSettle();
      expect(pressableScale(tester, find.byType(Pressable)), 1.0);
    });

    testWidgets('off ve kapsam yok: animasyon KURULMAZ, bırakınca ölçek anında 1.0, kare istenmez', (tester) async {
      for (final mode in <MotionMode?>[null, MotionMode.off]) {
        await tester.pumpWidget(designHost(pressable(onTap: () {}, overshoot: 1.04), mode: mode));
        final g = await tester.startGesture(tester.getCenter(find.byKey(box)));
        await tester.pump();
        await g.up();
        await tester.pump();
        expect(pressableScale(tester, find.byType(Pressable)), 1.0);
        expect(tester.hasRunningAnimations, isFalse);
        await tester.pump();
        expect(tester.binding.hasScheduledFrame, isFalse);
      }
    });

    testWidgets('disableAnimations: full kapsamda bile yaylanma yok', (tester) async {
      await tester.pumpWidget(designHost(pressable(onTap: () {}, overshoot: 1.04), mode: MotionMode.full, disableAnimations: true));
      await tester.tap(find.byKey(box));
      await tester.pump();
      expect(tester.hasRunningAnimations, isFalse);
    });
  });

  group('haptik', () {
    testWidgets('onTap ile aynı dokunuşta TEK çağrı; none hiç çağırmaz', (tester) async {
      final calls = recordHaptics(tester);
      var taps = 0;
      await tester.pumpWidget(designHost(pressable(onTap: () => taps++, haptic: PressHaptic.selection)));
      await tester.tap(find.byKey(box));
      expect(taps, 1);
      expect(calls, ['HapticFeedbackType.selectionClick']);

      await tester.pumpWidget(designHost(pressable(onTap: () => taps++, haptic: PressHaptic.none)));
      await tester.tap(find.byKey(box));
      expect(calls.length, 1);
    });

    testWidgets('light / medium / heavy doğru türü gönderir', (tester) async {
      final calls = recordHaptics(tester);
      for (final h in [PressHaptic.light, PressHaptic.medium, PressHaptic.heavy]) {
        await tester.pumpWidget(designHost(pressable(onTap: () {}, haptic: h)));
        await tester.tap(find.byKey(box));
      }
      expect(calls, ['HapticFeedbackType.lightImpact', 'HapticFeedbackType.mediumImpact', 'HapticFeedbackType.heavyImpact']);
    });

    testWidgets('devre dışıyken haptik yok', (tester) async {
      final calls = recordHaptics(tester);
      await tester.pumpWidget(designHost(pressable(onTap: () {}, enabled: false, haptic: PressHaptic.medium)));
      await tester.tap(find.byKey(box), warnIfMissed: false);
      expect(calls, isEmpty);
    });
  });

  testWidgets('builder: pressed bayrağı parmak değince true, kalkınca false', (tester) async {
    final seen = <bool>[];
    await tester.pumpWidget(
      designHost(
        Pressable(
          onTap: () {},
          builder: (context, pressed) {
            seen.add(pressed);
            return SizedBox(key: box, width: 80, height: 80, child: Text(pressed ? 'basılı' : 'serbest', textDirection: TextDirection.ltr));
          },
        ),
      ),
    );
    expect(find.text('serbest'), findsOneWidget);
    final g = await tester.startGesture(tester.getCenter(find.byKey(box)));
    await tester.pump();
    expect(find.text('basılı'), findsOneWidget);
    expect(find.text('serbest'), findsNothing, reason: 'eski+yeni metin birlikte olmaz');
    await g.up();
    await tester.pump();
    expect(find.text('serbest'), findsOneWidget);
    expect(seen, contains(true));
  });
}
