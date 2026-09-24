import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/wifi_recovery_dialog.dart';
import 'package:ev_otomasyon/ui/pages/device_settings_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ADIM 14: Wi-Fi Şifre Değişimi Kurtarma Modu (Smart AP Fallback) Tests', () {
    testWidgets('WifiRecoveryDialog renders step-by-step guidance and form elements without overflow', (tester) async {
      final state = AutomationState();
      addTearDown(() => state.dispose());

      await tester.pumpWidget(
        ChangeNotifierProvider<AutomationState>.value(
          value: state,
          child: const MaterialApp(
            home: Scaffold(
              body: WifiRecoveryDialog(),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Başlık ve bilgilendirmeler görünmeli
      expect(find.text('Wi-Fi Kurtarma Modu'), findsOneWidget);
      expect(find.text('Smart AP Fallback / Şifre Yenileme'), findsOneWidget);
      expect(find.text('Adım 1: Panonun Kurtarma Ağına Bağlanın'), findsOneWidget);
      expect(find.text('Pano Bağlantısını Test Et'), findsOneWidget);

      // Adım 2: Yeni Ev Wi-Fi Bilgileri formu
      expect(find.text('Adım 2: Yeni Ev Wi-Fi Bilgileri'), findsOneWidget);
      expect(find.text('Yeni Wi-Fi Ağ Adı (SSID)'), findsOneWidget);
      expect(find.text('Yeni Wi-Fi Şifresi'), findsOneWidget);
      expect(find.text('Yeni Wi-Fi Şifresini Panoya Yükle'), findsOneWidget);
    });

    testWidgets('WifiRecoveryDialog validates empty SSID before submission', (tester) async {
      final state = AutomationState();
      addTearDown(() => state.dispose());

      await tester.pumpWidget(
        ChangeNotifierProvider<AutomationState>.value(
          value: state,
          child: const MaterialApp(
            home: Scaffold(
              body: WifiRecoveryDialog(),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // SSID girmeden 'Yeni Wi-Fi Şifresini Panoya Yükle' butonuna tıkla
      final submitBtn = find.text('Yeni Wi-Fi Şifresini Panoya Yükle');
      await tester.ensureVisible(submitBtn);
      await tester.pumpAndSettle();
      await tester.tap(submitBtn);
      await tester.pumpAndSettle();

      // Hata uyarısı gösterilmeli
      expect(find.text('Lütfen yeni Wi-Fi ağ adını (SSID) girin.'), findsOneWidget);
    });

    testWidgets('WifiRecoveryDialog accepts SSID and password entry correctly', (tester) async {
      final state = AutomationState();
      addTearDown(() => state.dispose());

      await tester.pumpWidget(
        ChangeNotifierProvider<AutomationState>.value(
          value: state,
          child: const MaterialApp(
            home: Scaffold(
              body: WifiRecoveryDialog(),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      final textFields = find.byType(TextField);
      expect(textFields, findsNWidgets(2)); // SSID ve Şifre

      // SSID alanına yaz
      await tester.enterText(textFields.first, 'Yeni_Ev_WiFi_5G');
      await tester.pumpAndSettle();

      // Şifre alanına yaz
      await tester.enterText(textFields.last, 'SuperSifre123');
      await tester.pumpAndSettle();

      expect(find.text('Yeni_Ev_WiFi_5G'), findsOneWidget);
      expect(find.text('SuperSifre123'), findsOneWidget);
    });

    testWidgets('DeviceSettingsPage renders properly and displays device settings without overflow', (tester) async {
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

      expect(find.text('Cihaz & Sistem Ayarları'), findsOneWidget);
      expect(find.text('ESP32-S3 Cihaz IP Adresi'), findsOneWidget);
    });
  });
}
