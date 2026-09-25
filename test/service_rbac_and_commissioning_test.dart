import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/service_mode_page.dart';
import 'package:ev_otomasyon/ui/pages/device_settings_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ADIM 11 - RBAC & Commissioning UI Tests', () {
    testWidgets('ServiceModePage shows hardware protection and PIN login when not in service mode', (tester) async {
      final state = AutomationState();

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AutomationState>.value(
            value: state,
            child: const ServiceModePage(),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Donanım koruma uyarısını görmeli
      expect(find.text('🔒 Donanım & Motor Koruması Aktif'), findsOneWidget);
      expect(find.text('Yetkili Servis Girişi'), findsOneWidget);
      expect(find.text('Servis Oturumu Aç'), findsOneWidget);
    });

    testWidgets('DeviceSettingsPage displays hardware protection notice and settings title', (tester) async {
      final state = AutomationState();

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AutomationState>.value(
            value: state,
            child: const DeviceSettingsPage(),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Donanım koruma uyarısını görmeli
      expect(find.text('🔒 Donanım & Motor Koruması'), findsOneWidget);
      expect(find.text('Cihaz & Sistem Ayarları'), findsOneWidget);
      expect(find.text('ESP32-S3 Cihaz IP Adresi'), findsOneWidget);
    });

    test('AutomationState role-based getters work as expected', () {
      final state = AutomationState();
      expect(state.isServiceMode, isFalse);
      expect(state.isInstaller, isFalse);
      expect(state.isOwner, isFalse);
      expect(state.isMember, isFalse);
    });
  });
}
