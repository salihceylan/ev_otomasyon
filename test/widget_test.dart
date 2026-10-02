import 'package:ev_otomasyon/main.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/app_shell.dart';
import 'package:ev_otomasyon/ui/pages/auth/login_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'support/support.dart';

/// Uygulama kökü: `EvOtomasyonApp` kabuğu kurar; kimlik çözülene kadar açılış ekranı, çözülünce
/// (sabit bir bekleme olmadan) oturum yoksa giriş ekranı gelir.
void main() {
  setUpAll(() {
    // Testte ağdan yazı tipi indirilmez.
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('uygulama açılır: kimlik çözülene kadar açılış ekranı, oturum yoksa hemen giriş ekranı gelir', (tester) async {
    final h = StateHarness();
    addTearDown(h.dispose);
    h.state.setAuthStatusForTesting(AuthStatus.checking);
    tester.view.physicalSize = const Size(540, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<AutomationState>.value(
        value: h.state,
        child: const EvOtomasyonApp(),
      ),
    );
    expect(find.byType(AppShell), findsOneWidget);
    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.text('AHBU OTOMASYON'), findsOneWidget, reason: 'açılış ekranı');
    expect(find.byType(LoginPage), findsNothing, reason: 'kimlik çözülmeden giriş ekranı gösterilmez');

    // Kimlik çözülünce giriş ekranı gelir; yalnızca geçiş animasyonu kadar beklenir (2,6 sn değil).
    h.state.setAuthStatusForTesting(AuthStatus.unauthenticated);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(LoginPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tema modu değişince kök uygulama yeni temayı kullanır', (tester) async {
    final h = StateHarness();
    addTearDown(h.dispose);
    h.state.setAuthStatusForTesting(AuthStatus.unauthenticated);
    await tester.pumpWidget(
      ChangeNotifierProvider<AutomationState>.value(value: h.state, child: const EvOtomasyonApp()),
    );
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode, ThemeMode.dark);

    h.state.setThemeModeForTesting(ThemeMode.light);
    await tester.pump();
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode, ThemeMode.light);
  });
}
