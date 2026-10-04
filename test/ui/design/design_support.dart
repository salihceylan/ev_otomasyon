// Tasarım sistemi (Neon Glass) testleri için ortak yardımcılar.
import 'dart:async';

import 'package:ev_otomasyon/ui/motion/ambient_clock.dart';
import 'package:ev_otomasyon/ui/motion/motion_scope.dart';
import 'package:ev_otomasyon/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Test için küçük uygulama: kapsam [mode] verilirse `MotionScope`, aksi halde KAPSAM YOK (varsayılan off).
///
/// [disableAnimations] sistem "animasyonları kaldır" ayarını taklit eder. Tema, google_fonts'a dokunmaz
/// (`ThemeData.light/dark`); `AppTheme` özel testleri kendi temasını kurar.
Widget designHost(
  Widget child, {
  MotionMode? mode,
  AmbientClock? clock,
  Brightness brightness = Brightness.dark,
  bool disableAnimations = false,
  double textScale = 1.0,
  bool center = true,
}) {
  Widget app = MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.light(),
    darkTheme: ThemeData.dark(),
    themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
    builder: (context, c) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        disableAnimations: disableAnimations,
        textScaler: TextScaler.linear(textScale),
      ),
      child: c!,
    ),
    home: Scaffold(body: center ? Center(child: child) : child),
  );
  if (mode != null) app = MotionScope(mode: mode, clock: clock, child: app);
  return app;
}

/// [finder]'ın ilk eşleşmesinin üst zincirindeki tüm `FadeTransition` opaklıklarının çarpımı.
double effectiveOpacity(WidgetTester tester, Finder finder) {
  final element = tester.element(finder.first);
  var opacity = 1.0;
  element.visitAncestorElements((ancestor) {
    final w = ancestor.widget;
    if (w is FadeTransition) opacity *= w.opacity.value;
    if (w is Opacity) opacity *= w.opacity;
    return true;
  });
  return opacity;
}

/// `Pressable`'ın en dıştaki `Transform.scale` değeri.
double pressableScale(WidgetTester tester, Finder pressable) {
  final transform = tester.widgetList<Transform>(find.descendant(of: pressable, matching: find.byType(Transform))).first;
  return transform.transform.storage[0]; // x ekseni ölçeği (getMaxScaleOnAxis z=1 yüzünden hep 1 olurdu)
}

/// `SystemChannels.platform` haptik çağrılarını kaydeder (argüman: 'HapticFeedbackType.selectionClick' ...).
List<String> recordHaptics(WidgetTester tester) {
  final calls = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'HapticFeedback.vibrate') calls.add(call.arguments as String);
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  return calls;
}

/// Bekleyen kare/animasyon yok mu (ambient ticker dahil)?
bool isIdle(WidgetTester tester) => !tester.binding.hasScheduledFrame;

/// `AppTheme`'i, google_fonts'un asenkron Inter yükleme HATASINI yutan bir bölgede kurar. Test GERÇEK async
/// (`tester.runAsync`) beklerse, aksi halde bu hata teste sızıp onu düşürürdü.
ThemeData guardedAppTheme(Brightness brightness) => runZonedGuarded<ThemeData>(
      () => brightness == Brightness.dark ? AppTheme.darkTheme : AppTheme.lightTheme,
      (Object error, StackTrace stack) {},
    )!;
