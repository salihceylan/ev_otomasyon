import 'dart:io';

import 'package:ev_otomasyon/main.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/motion/motion.dart';
import 'package:ev_otomasyon/ui/pages/auth/login_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../support/support.dart';

/// `lib/main.dart` sözleşmesi: `MotionMode.full` YALNIZ `runApp` sarmalayıcısında verilir; `EvOtomasyonApp`'i
/// (ve `buildApp`'i) doğrudan pompalayan testler `off` görür.
void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  testWidgets('EvOtomasyonApp doğrudan pompalanınca MotionScope YOK ⇒ off; ambient saat çalışmaz', (tester) async {
    final h = StateHarness();
    addTearDown(h.dispose);
    h.state.setAuthStatusForTesting(AuthStatus.unauthenticated);
    tester.view.physicalSize = const Size(540, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ChangeNotifierProvider<AutomationState>.value(value: h.state, child: const EvOtomasyonApp()));
    await tester.pump();
    expect(find.byType(MotionScope), findsNothing);
    expect(find.byType(LoginPage), findsOneWidget);
    final context = tester.element(find.byType(LoginPage));
    expect(MotionScope.modeOf(context), MotionMode.off);
    expect(AmbientClock.shared.isTicking, isFalse);
    // Tema yükseltmesiyle (fade-through geçişi, gradyan düğmeler, orb/yüzey yok) kök uygulama pumpAndSettle eder.
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('buildApp() de kapsam eklemez (integration_test/QA aynı ağacı off ile başlatır)', (tester) async {
    final h = StateHarness();
    addTearDown(h.dispose);
    h.state.setAuthStatusForTesting(AuthStatus.unauthenticated);
    tester.view.physicalSize = const Size(540, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final app = await buildApp(state: h.state);
    await tester.pumpWidget(app);
    await tester.pump();
    expect(find.byType(MotionScope), findsNothing);
  });

  test('main(): runApp, MotionScope(mode: full) ile sarılır; yalnız orada', () {
    final src = File('lib/main.dart').readAsStringSync();
    expect(src, contains('runApp(MotionScope(mode: MotionMode.full, child: await buildApp()));'));
    final withoutMain = src.replaceFirst('runApp(MotionScope(mode: MotionMode.full, child: await buildApp()));', '');
    expect(withoutMain.contains('MotionMode.full'), isFalse, reason: 'full kip başka yerde verilmez');
    final shellBody = RegExp(r'class EvOtomasyonApp[\s\S]*').firstMatch(src)!.group(0)!;
    expect(shellBody.contains('MotionScope'), isFalse);
  });
}
