import 'package:ev_otomasyon/ui/motion/motion.dart';
import 'package:ev_otomasyon/ui/widgets/neon_app_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Hareket v3 / B3: NeonAppBar orb'u açılışta tek sefer belirir; başlık animasyonsuz; AppBar türü ve geri anahtarı aynen.
void main() {
  Widget host(MotionMode mode) => MotionScope(
    mode: mode,
    child: MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              key: const Key('open'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(appBar: NeonAppBar(title: 'Başlık', icon: Icons.settings_rounded)),
                ),
              ),
              child: const Text('aç'),
            ),
          ),
        ),
      ),
    ),
  );

  double orbOpacity(WidgetTester tester) {
    final entrance = find.descendant(of: find.byType(AppBar), matching: find.byType(StaggeredEntrance));
    expect(entrance, findsOneWidget);
    final fade = tester.widget<FadeTransition>(find.descendant(of: entrance, matching: find.byType(FadeTransition)).first);
    return fade.opacity.value;
  }

  testWidgets('off: orb anında tam görünür, AppBar ve nav_back korunur', (tester) async {
    await tester.pumpWidget(host(MotionMode.off));
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byKey(const Key('nav_back')), findsOneWidget);
    expect(find.text('Başlık'), findsOneWidget);
    expect(orbOpacity(tester), 1.0);
    // Başlık metni giriş animasyonunun içinde değil.
    expect(find.descendant(of: find.byType(StaggeredEntrance), matching: find.text('Başlık')), findsNothing);
  });

  testWidgets('full: geçiş sonunda orb tam görünür', (tester) async {
    await tester.pumpWidget(host(MotionMode.full));
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();
    expect(orbOpacity(tester), 1.0);
    expect(find.text('Başlık'), findsOneWidget);
  });
}
