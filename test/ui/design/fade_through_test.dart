import 'package:ev_otomasyon/ui/motion/motion.dart';
import 'package:ev_otomasyon/ui/theme/app_theme.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

import 'design_support.dart';

/// Fade-through sayfa geçişi: giden sayfa ilk %35'te solar, gelen sonraki %65'te belirir; iki sayfa aynı anda
/// tam opak OLMAZ; ≤ 280 ms; tüm platformlar tema üzerinden.
void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  final navKey = GlobalKey<NavigatorState>();

  Widget app({TargetPlatform platform = TargetPlatform.android}) => MaterialApp(
        navigatorKey: navKey,
        theme: ThemeData(platform: platform, pageTransitionsTheme: AppTheme.pageTransitions),
        home: const Scaffold(backgroundColor: Colors.transparent, body: Center(child: Text('A'))),
      );

  void pushB() => navKey.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Scaffold(backgroundColor: Colors.transparent, body: Center(child: Text('B')))),
      );

  Finder a() => find.text('A', skipOffstage: false);
  Finder b() => find.text('B', skipOffstage: false);

  testWidgets('tema: tüm platformlar FadeThroughPageTransitionsBuilder kullanır (açık ve koyu)', (tester) async {
    for (final theme in [AppTheme.lightTheme, AppTheme.darkTheme]) {
      final builders = theme.pageTransitionsTheme.builders;
      for (final p in TargetPlatform.values) {
        expect(builders[p], isA<FadeThroughPageTransitionsBuilder>(), reason: '$p');
      }
    }
    expect(AppTheme.pageTransitions.builders.keys.toSet(), TargetPlatform.values.toSet());
  });

  testWidgets('süre ≤ 280 ms (ileri ve geri)', (tester) async {
    const builder = FadeThroughPageTransitionsBuilder();
    expect(builder.transitionDuration.inMilliseconds, lessThanOrEqualTo(280));
    expect(builder.reverseTransitionDuration.inMilliseconds, lessThanOrEqualTo(280));
    await tester.pumpWidget(app());
    pushB();
    await tester.pump(); // rotayı ekle
    await tester.pump(const Duration(milliseconds: 281));
    expect(tester.hasRunningAnimations, isFalse, reason: 'geçiş 281 ms\'de bitmiş olmalı');
    expect(effectiveOpacity(tester, find.text('B')), 1.0);
  });

  testWidgets('ileri geçiş: iki sayfa HİÇBİR karede birlikte görünür değil; giden önce solar, gelen sonra belirir', (tester) async {
    await tester.pumpWidget(app());
    expect(effectiveOpacity(tester, a()), 1.0);
    pushB();
    await tester.pump();

    final samples = <(double t, double a, double b)>[];
    for (var i = 0; i <= 17; i++) {
      samples.add((i * 16.0, effectiveOpacity(tester, a()), effectiveOpacity(tester, b())));
      await tester.pump(const Duration(milliseconds: 16));
    }

    for (final (t, oa, ob) in samples) {
      expect(oa < 0.999 || ob < 0.999, isTrue, reason: 't=$t: iki sayfa aynı anda tam opak: A=$oa B=$ob');
      // Saydam scaffold "hayaleti" YOK: biri solmuş olmadan öteki belirmeye başlamaz.
      expect(oa > 0.001 && ob > 0.001, isFalse, reason: 't=$t: iki sayfa birlikte yarı saydam görünür: A=$oa B=$ob');
      expect(oa + ob, lessThanOrEqualTo(1.0 + 1e-9), reason: 't=$t');
    }
    // Başlangıçta A tam, B yok; sonda B tam, A yok.
    expect(samples.first.$2, 1.0);
    expect(samples.first.$3, 0.0);
    expect(samples.last.$3, closeTo(1.0, 0.02));
    // Giden ilk %35'te (≈ 91 ms) solmuş olmalı; gelen o ana kadar hiç belirmemiş.
    final early = samples.where((s) => s.$1 <= 80).toList();
    expect(early.every((s) => s.$3 == 0.0), isTrue, reason: 'gelen sayfa ilk %35\'te görünmez');
    final late = samples.where((s) => s.$1 >= 112 && s.$1 <= 160).toList();
    expect(late.every((s) => s.$2 == 0.0), isTrue, reason: 'giden sayfa %35 sonrası tamamen gitmiş');
    expect(samples.any((s) => s.$2 > 0.01 && s.$2 < 0.99), isTrue, reason: 'giden gerçekten solar (ara değer)');
    expect(samples.any((s) => s.$3 > 0.01 && s.$3 < 0.99), isTrue, reason: 'gelen gerçekten belirir (ara değer)');
    await tester.pumpAndSettle();
    expect(effectiveOpacity(tester, b()), 1.0);
  });

  testWidgets('geri geçiş (pop): aynı kural, iki sayfa birlikte tam opak değil; sonda A tam', (tester) async {
    await tester.pumpWidget(app());
    pushB();
    await tester.pumpAndSettle();
    navKey.currentState!.pop();
    await tester.pump();
    for (var i = 0; i <= 16; i++) {
      // Geri geçiş bitince B rotası ağaçtan kalkar (eleman yok = görünmez).
      final oa = tester.any(a()) ? effectiveOpacity(tester, a()) : 0.0;
      final ob = tester.any(b()) ? effectiveOpacity(tester, b()) : 0.0;
      expect(oa < 0.999 || ob < 0.999, isTrue, reason: 'pop t=${i * 16}: A=$oa B=$ob');
      expect(oa > 0.001 && ob > 0.001, isFalse, reason: 'pop t=${i * 16}: hayalet A=$oa B=$ob');
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();
    expect(effectiveOpacity(tester, a()), 1.0);
    expect(find.text('B'), findsNothing);
  });

  testWidgets('iOS platformunda bile Cupertino kaydırma geçişi YOK (fade-through)', (tester) async {
    await tester.pumpWidget(app(platform: TargetPlatform.iOS));
    pushB();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(CupertinoPageTransition), findsNothing);
    expect(find.descendant(of: find.byType(MaterialApp), matching: find.byType(FadeTransition)), findsWidgets);
    await tester.pumpAndSettle();
  });

  testWidgets('geçiş sırasında yeni sayfaya dokunuş engellenmez (animasyon girdiyi bloklamaz)', (tester) async {
    var taps = 0;
    await tester.pumpWidget(app());
    navKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          backgroundColor: Colors.transparent,
          body: Center(child: GestureDetector(key: const Key('tapme'), behavior: HitTestBehavior.opaque, onTap: () => taps++, child: const SizedBox(width: 80, height: 80))),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byKey(const Key('tapme')));
    expect(taps, 1);
    await tester.pumpAndSettle();
  });
}
