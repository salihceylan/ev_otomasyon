import 'package:ev_otomasyon/ui/motion/ambient_clock.dart';
import 'package:ev_otomasyon/ui/motion/motion_scope.dart';
import 'package:ev_otomasyon/ui/pages/claim/scanner_frame.dart';
import 'package:ev_otomasyon/ui/pages/family/countdown_ring.dart';
import 'package:ev_otomasyon/ui/pages/family/step_progress.dart';
import 'package:ev_otomasyon/ui/theme/tokens.dart';
import 'package:ev_otomasyon/ui/widgets/settings/settings_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// WP-V4: ayarlar/aile/claim için yeni görsel bileşenlerin davranış testleri (hareket kapalı kipte
/// `pumpAndSettle` takılmaz; tam kipte sabit saatle zamanlayıcı/ticker kalmaz).
void main() {
  Widget host(Widget child, {MotionMode? mode}) {
    final app = MaterialApp(home: Scaffold(body: Center(child: child)));
    if (mode == null) return app;
    return MotionScope(mode: mode, clock: AmbientClock.fixed(0.5), child: app);
  }

  testWidgets('SettingsSection: başlık tam 1 kez, boşsa hiçbir şey çizmez; kartlar sırayla', (tester) async {
    await tester.pumpWidget(host(const SettingsSection(
      title: 'Güvenlik',
      icon: Icons.shield_rounded,
      family: AppFamilies.amber,
      children: [Text('kart 1'), Text('kart 2')],
    )));
    await tester.pumpAndSettle();
    expect(find.text('Güvenlik'), findsOneWidget);
    expect(find.text('kart 1'), findsOneWidget);
    expect(find.text('kart 2'), findsOneWidget);

    await tester.pumpWidget(host(const SettingsSection(
      title: 'Boş',
      icon: Icons.shield_rounded,
      family: AppFamilies.amber,
      children: [],
    )));
    expect(find.text('Boş'), findsNothing);
  });

  testWidgets('familyForAccent en yakın aileyi seçer', (tester) async {
    expect(familyForAccent(const Color(0xFFFFB020)), AppFamilies.amber);
    expect(familyForAccent(const Color(0xFF10B981)), AppFamilies.emerald);
    expect(familyForAccent(const Color(0xFFF43F5E)), AppFamilies.rose);
  });

  testWidgets('StepProgress: anlamsal adım özeti verir', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(host(const StepProgress(step: 2, total: 3, color: AppFamilies.sky)));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Adım 2 / 3'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('CountdownRing: sabit saatte ve kapalı kipte kalıcı zamanlayıcı/kare istemez', (tester) async {
    final now = DateTime.utc(2026, 10, 1, 12);
    for (final mode in <MotionMode?>[null, MotionMode.full]) {
      await tester.pumpWidget(host(
        CountdownRing(
          expiresAt: now.add(const Duration(hours: 6)),
          total: const Duration(hours: 24),
          now: () => now,
          color: Colors.amber,
        ),
        mode: mode,
      ));
      await tester.pumpAndSettle();
      expect(find.byType(CountdownRing), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('ScannerFrame: kabulde ✓ görünür, tarama çizgisi saati dinlemez; etkileşimi engellemez', (tester) async {
    await tester.pumpWidget(host(const ScannerFrame(size: 200), mode: MotionMode.full));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('scanner_success_check')), findsNothing);
    expect(find.descendant(of: find.byType(ScannerFrame), matching: find.byType(IgnorePointer)), findsWidgets);

    await tester.pumpWidget(host(const ScannerFrame(size: 200, accepted: true), mode: MotionMode.full));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('scanner_success_check')), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
  });
}
