import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/auth/login_page.dart';
import 'package:ev_otomasyon/ui/pages/auth/phone_otp_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({'saved_app_mode': 'cloud'});
  });

  group('ADIM 18: Sosyal & Şifresiz Giriş (Google, Apple & Telefon OTP) Tests', () {
    testWidgets('LoginPage renders Google, Apple and Phone OTP buttons without overflow', (tester) async {
      tester.view.physicalSize = const Size(400, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final state = AutomationState();
      addTearDown(() => state.dispose());

      await tester.pumpWidget(
        ChangeNotifierProvider<AutomationState>.value(
          value: state,
          child: const MaterialApp(
            home: LoginPage(),
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 100));

      // Sosyal & Şifresiz butonları bul
      expect(find.text('Google ile Devam Et'), findsOneWidget);
      expect(find.text('Apple ile Giriş Yap'), findsOneWidget);
      expect(find.text('Telefon Numarası ile Şifresiz Giriş (SMS)'), findsOneWidget);
      expect(find.text('Teknisyen / Kurulumcu Girişi (PIN)'), findsOneWidget);
      expect(find.text('Yerel Ağ Modu (ESP32 Doğrudan Erişim)'), findsOneWidget);

      expect(tester.takeException(), isNull);
    });

    testWidgets('PhoneOtpDialog renders phone number input and actions properly', (tester) async {
      tester.view.physicalSize = const Size(500, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final state = AutomationState();
      addTearDown(() => state.dispose());

      await tester.pumpWidget(
        ChangeNotifierProvider<AutomationState>.value(
          value: state,
          child: const MaterialApp(
            home: Scaffold(
              body: PhoneOtpDialog(),
            ),
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Şifresiz SMS Girişi'), findsOneWidget);
      expect(find.text('Telefon Numarası'), findsOneWidget);
      expect(find.text('Kod Gönder'), findsOneWidget);
      expect(find.text('İptal'), findsOneWidget);

      // Telefon numarası girme
      final phoneField = find.byType(TextField).first;
      await tester.enterText(phoneField, '05551234567');
      await tester.pump();

      expect(find.text('05551234567'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Tapping Telefon Numarası ile Şifresiz Giriş opens PhoneOtpDialog', (tester) async {
      tester.view.physicalSize = const Size(450, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final state = AutomationState();
      addTearDown(() => state.dispose());

      await tester.pumpWidget(
        ChangeNotifierProvider<AutomationState>.value(
          value: state,
          child: const MaterialApp(
            home: LoginPage(),
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 100));

      final otpButton = find.text('Telefon Numarası ile Şifresiz Giriş (SMS)');
      expect(otpButton, findsOneWidget);

      await tester.tap(otpButton);
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(PhoneOtpDialog), findsOneWidget);
      expect(find.text('Şifresiz SMS Girişi'), findsOneWidget);

      // İptal butonuna basarak kapat
      final cancelButton = find.text('İptal');
      await tester.tap(cancelButton);
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(PhoneOtpDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}

