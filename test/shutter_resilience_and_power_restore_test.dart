import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ev_otomasyon/models/automation_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/widgets/shutter_card.dart';
import 'package:ev_otomasyon/ui/pages/device_settings_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ADIM 15: Panjur Over-Run (+2 sn) & Elektrik Kesintisi Güvenliği Tests', () {
    testWidgets('ShutterCard renders title, status, and limit protection without overflow', (tester) async {
      final state = AutomationState();
      addTearDown(() => state.dispose());

      final shutter = ShutterItem(
        pairIndex: 0,
        name: 'Salon Panjur',
        isMoving: false,
        direction: 0,
        runtimeSec: 20,
      );

      await tester.pumpWidget(
        ChangeNotifierProvider<AutomationState>.value(
          value: state,
          child: MaterialApp(
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(16.0),
                child: ShutterCard(shutter: shutter),
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Başlık, rozetler ve koruma bilgisi görünmeli
      expect(find.text('🪟 Salon Panjur'), findsOneWidget);
      expect(find.text('Durum: Durdu'), findsOneWidget);
      expect(find.text('0%: Kapalı • 100%: Tam Açık (Limit Korumalı)'), findsOneWidget);

      // Butonlar görünmeli
      expect(find.text('▲ AÇ'), findsOneWidget);
      expect(find.text('⏹ DURDUR'), findsOneWidget);
      expect(find.text('▼ KAPAT'), findsOneWidget);
    });

    testWidgets('ShutterCard moving state reflects direction accurately', (tester) async {
      final state = AutomationState();
      addTearDown(() => state.dispose());

      final movingShutter = ShutterItem(
        pairIndex: 0,
        name: 'Yatak Odası Panjur',
        isMoving: true,
        direction: 1, // Açılıyor
        runtimeSec: 20,
      );

      await tester.pumpWidget(
        ChangeNotifierProvider<AutomationState>.value(
          value: state,
          child: MaterialApp(
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(16.0),
                child: ShutterCard(shutter: movingShutter),
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Durum: Açılıyor...'), findsOneWidget);
    });

    testWidgets('DeviceSettingsPage displays power-restore safety and self-healing calibration notice', (tester) async {
      final state = AutomationState();
      addTearDown(() => state.dispose());

      await tester.pumpWidget(
        ChangeNotifierProvider<AutomationState>.value(
          value: state,
          child: const MaterialApp(
            home: DeviceSettingsPage(),
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('🔒 Donanım & Motor Koruması'), findsOneWidget);
      expect(
        find.textContaining('Elektrik kesintisi dönüşünde lambalar kapalı kalır, panjurlar hareket etmez'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Tam açma/kapamada +2 sn mekanik limit oturması ve self-healing kalibrasyonu devrededir'),
        findsOneWidget,
      );
    });
  });
}
