import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'fakes.dart';

/// Bir sayfayı/bileşeni `AutomationState` sağlayıcısı ve `MaterialApp` ile pompalar.
///
/// * [state] verilmezse tüm sahteleri içeren (ağ/MQTT/depolama yok) bir durum kurulur ve test
///   sonunda kapatılır.
/// * Ekran boyutu [size] (varsayılan 800x1400 mantıksal piksel, DPR 1.0) ve test sonunda sıfırlanır.
/// * Dönen değer kullanılan durumdur (test içinde `state.setXForTesting` ile hazırlanır).
///
/// ```dart
/// testWidgets('...', (tester) async {
///   final state = await pumpApp(tester, child: const DashboardPage());
///   state.setHomesForTesting([testHome()]);
///   await tester.pump();
/// });
/// ```
Future<AutomationState> pumpApp(
  WidgetTester tester, {
  required Widget child,
  AutomationState? state,
  Size size = const Size(800, 1400),
  ThemeMode themeMode = ThemeMode.dark,
  ThemeData? theme,
  ThemeData? darkTheme,
  bool settle = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  late final AutomationState effective;
  if (state != null) {
    effective = state;
  } else {
    final harness = StateHarness();
    addTearDown(harness.dispose);
    effective = harness.state;
  }

  await tester.pumpWidget(
    ChangeNotifierProvider<AutomationState>.value(
      value: effective,
      child: MaterialApp(
        themeMode: themeMode,
        theme: theme,
        darkTheme: darkTheme,
        home: child,
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  return effective;
}
