import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/auth/forgot_password_dialog.dart';
import 'package:ev_otomasyon/ui/pages/auth/login_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({'saved_app_mode': 'cloud'});
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('ADIM 20: Sürtünmesiz Şifre Yenileme & Sıfır-Stres Hesap Kurtarma Tests', () {
    testWidgets('ForgotPasswordDialog renders step 1 form elements without overflow', (tester) async {
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
              body: ForgotPasswordDialog(),
            ),
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Şifre Yenileme'), findsOneWidget);
      expect(find.text('Sıfır-Stres Hesap Kurtarma'), findsOneWidget);
      expect(find.text('E-posta veya Telefon'), findsOneWidget);
      expect(find.text('Kod Gönder'), findsOneWidget);
      expect(find.text('İptal'), findsOneWidget);

      // Metin girişi testi
      final textField = find.byType(TextField).first;
      await tester.enterText(textField, 'test@ahbu.com');
      await tester.pump();

      expect(find.text('test@ahbu.com'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Tapping Şifremi Unuttum on LoginPage opens ForgotPasswordDialog without overflow', (tester) async {
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

      final forgotButton = find.text('Şifremi Unuttum');
      expect(forgotButton, findsOneWidget);

      await tester.tap(forgotButton);
      await tester.pumpAndSettle();

      expect(find.text('Şifre Yenileme'), findsOneWidget);
      expect(find.text('Sıfır-Stres Hesap Kurtarma'), findsOneWidget);
      expect(find.text('Kod Gönder'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('ForgotPasswordDialog validates short identifier before sending', (tester) async {
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
              body: ForgotPasswordDialog(),
            ),
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 100));

      // Boşken Kod Gönder butonuna tıkla
      await tester.tap(find.text('Kod Gönder'));
      await tester.pump();

      expect(find.textContaining('Lütfen geçerli bir e-posta'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

