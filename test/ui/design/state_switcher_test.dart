import 'package:ev_otomasyon/ui/motion/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'design_support.dart';

/// `StateSwitcher` (hareket v3 §2.3, §3): yükleme → içerik → boş/hata geçişi. Ağaçta her an TEK çocuk (eski+yeni
/// metin birlikte olmaz); full kipte solma + 8 dp yukarı kayma (220 ms); off kipinde anında.
void main() {
  Widget host(Object state, String text, {MotionMode? mode, bool disableAnimations = false}) => designHost(
        StateSwitcher(stateKey: state, child: Text(text)),
        mode: mode,
        disableAnimations: disableAnimations,
        center: false,
      );

  group('off: anında, ara durum yok', () {
    final variants = <String, ({MotionMode? mode, bool disable})>{
      'kapsam yok': (mode: null, disable: false),
      'MotionMode.off': (mode: MotionMode.off, disable: false),
      'disableAnimations': (mode: MotionMode.full, disable: true),
    };
    for (final e in variants.entries) {
      testWidgets(e.key, (tester) async {
        await tester.pumpWidget(host('loading', 'yükleniyor', mode: e.value.mode, disableAnimations: e.value.disable));
        await tester.pumpWidget(host('content', 'içerik', mode: e.value.mode, disableAnimations: e.value.disable));
        await tester.pump();
        expect(find.text('içerik'), findsOneWidget);
        expect(find.text('yükleniyor'), findsNothing);
        expect(effectiveOpacity(tester, find.text('içerik')), 1.0);
        expect(tester.hasRunningAnimations, isFalse);
        await tester.pumpAndSettle();
      });
    }
  });

  testWidgets('full: geçiş sırasında tek çocuk; solarak ve 8 dp aşağıdan gelir; 220 ms sonunda yerinde', (tester) async {
    await tester.pumpWidget(host('loading', 'yükleniyor', mode: MotionMode.full));
    await tester.pumpAndSettle();
    final restY = tester.getTopLeft(find.text('yükleniyor')).dy;
    await tester.pumpWidget(host('content', 'içerik', mode: MotionMode.full));
    await tester.pump();
    expect(find.text('yükleniyor'), findsNothing, reason: 'eski çocuk hemen kalkar');
    expect(find.text('içerik'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 60));
    final o = effectiveOpacity(tester, find.text('içerik'));
    expect(o, greaterThan(0.0));
    expect(o, lessThan(1.0));
    final dy = tester.getTopLeft(find.text('içerik')).dy - restY;
    expect(dy, greaterThan(0.0));
    expect(dy, lessThanOrEqualTo(8.0));
    await tester.pump(const Duration(milliseconds: 160)); // toplam 220 ms
    expect(effectiveOpacity(tester, find.text('içerik')), 1.0);
    expect(tester.getTopLeft(find.text('içerik')).dy, restY);
    await tester.pumpAndSettle();
  });

  testWidgets('aynı stateKey: çocuk değişse de animasyon yok (yalnız durum değişimi canlanır)', (tester) async {
    await tester.pumpWidget(host('content', 'bir', mode: MotionMode.full));
    await tester.pumpAndSettle();
    await tester.pumpWidget(host('content', 'iki', mode: MotionMode.full));
    await tester.pump();
    expect(find.text('iki'), findsOneWidget);
    expect(effectiveOpacity(tester, find.text('iki')), 1.0);
    expect(tester.hasRunningAnimations, isFalse);
  });
}
