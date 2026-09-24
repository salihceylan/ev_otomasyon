import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/dashboard_page.dart';
import 'package:ev_otomasyon/ui/pages/claim/claim_manual_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({'saved_app_mode': 'cloud'});
  });

  group('FAZ 8.3 - Welcome Card & Claim Flow Tests', () {
    testWidgets('DashboardPage displays Welcome Claim Card when cloud endpoints are empty', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final state = AutomationState();
      addTearDown(() => state.dispose());

      await state.setMode(AppMode.cloud);

      await tester.pumpWidget(
        MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<AutomationState>.value(value: state),
            ],
            child: const DashboardPage(),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Karşılama kartı elemanları görünür olmalıdır
      expect(find.text('Evinize Hoş Geldiniz!'), findsOneWidget);
      expect(find.text('Karekod ile Cihaz Eşle'), findsOneWidget);
      expect(find.text('Kodu Elle Gir (Manuel Eşleme)'), findsOneWidget);

      // Kodu Elle Gir butonuna basıldığında ClaimManualDialog açılmalıdır
      final manualBtn = find.text('Kodu Elle Gir (Manuel Eşleme)');
      await tester.ensureVisible(manualBtn);
      await tester.tap(manualBtn);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(ClaimManualDialog), findsOneWidget);
      expect(find.text('Cihaz Eşleştirme'), findsOneWidget);
    });

    testWidgets('DashboardPage AppBar has QR scanner button', (WidgetTester tester) async {
      final state = AutomationState();
      addTearDown(() => state.dispose());

      await tester.pumpWidget(
        MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<AutomationState>.value(value: state),
            ],
            child: const DashboardPage(),
          ),
        ),
      );

      await tester.pump();
      expect(find.byIcon(Icons.qr_code_scanner), findsOneWidget);
    });
  });
}
