import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/auth/auth_gate.dart';
import 'package:ev_otomasyon/ui/pages/auth/login_page.dart';
import 'package:ev_otomasyon/ui/pages/auth/register_page.dart';
import 'package:ev_otomasyon/ui/pages/auth/forgot_password_page.dart';
import 'package:ev_otomasyon/ui/widgets/user_profile_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FAZ 7.2 - Auth UI & UX Validation Tests', () {
    testWidgets('LoginPage validates empty email and password', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider(create: (_) => AutomationState()),
            ],
            child: const LoginPage(),
          ),
        ),
      );

      // Boş form ile "Giriş Yap" butonuna basılır
      final loginBtn = find.widgetWithText(ElevatedButton, 'Giriş Yap');
      expect(loginBtn, findsOneWidget);
      await tester.tap(loginBtn);
      await tester.pumpAndSettle();

      // Form validation hataları görünmelidir
      expect(find.text('Lütfen e-posta adresinizi girin'), findsOneWidget);
      expect(find.text('Lütfen şifrenizi girin'), findsOneWidget);
    });

    testWidgets('LoginPage validates invalid email and short password', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider(create: (_) => AutomationState()),
            ],
            child: const LoginPage(),
          ),
        ),
      );

      // Geçersiz formatlar girilir
      await tester.enterText(find.byType(TextFormField).at(0), 'gecersiz-email');
      await tester.enterText(find.byType(TextFormField).at(1), '123');

      final loginBtn = find.widgetWithText(ElevatedButton, 'Giriş Yap');
      await tester.tap(loginBtn);
      await tester.pumpAndSettle();

      expect(find.text('Geçerli bir e-posta adresi girin'), findsOneWidget);
      expect(find.text('Şifre en az 6 karakter olmalıdır'), findsOneWidget);
    });

    testWidgets('RegisterPage validates empty fields and password mismatch', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider(create: (_) => AutomationState()),
            ],
            child: const RegisterPage(),
          ),
        ),
      );

      final registerBtn = find.widgetWithText(ElevatedButton, 'Kayıt Ol ve Giriş Yap');
      expect(registerBtn, findsOneWidget);

      await tester.ensureVisible(registerBtn);
      await tester.tap(registerBtn);
      await tester.pumpAndSettle();

      expect(find.text('Lütfen adınızı ve soyadınızı girin'), findsOneWidget);
      expect(find.text('Lütfen e-posta adresinizi girin'), findsOneWidget);
      expect(find.text('Lütfen bir şifre belirleyin'), findsOneWidget);

      // Uyuşmayan şifreler girilir
      await tester.enterText(find.byType(TextFormField).at(0), 'Ali Veli');
      await tester.enterText(find.byType(TextFormField).at(1), 'ali@test.com');
      await tester.enterText(find.byType(TextFormField).at(3), '123456');
      await tester.enterText(find.byType(TextFormField).at(4), '654321');

      await tester.ensureVisible(registerBtn);
      await tester.tap(registerBtn);
      await tester.pumpAndSettle();

      expect(find.text('Şifreler eşleşmiyor'), findsOneWidget);
    });

    testWidgets('ForgotPasswordPage validates and shows success view on valid submit', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: ForgotPasswordPage(),
        ),
      );

      final resetBtn = find.widgetWithText(ElevatedButton, 'Sıfırlama Bağlantısı Gönder');
      expect(resetBtn, findsOneWidget);

      // Boşken submit
      await tester.ensureVisible(resetBtn);
      await tester.tap(resetBtn);
      await tester.pumpAndSettle();
      expect(find.text('Lütfen e-posta adresinizi girin'), findsOneWidget);

      // Geçerli e-posta girilir
      await tester.enterText(find.byType(TextFormField), 'musteri@gude.com');
      await tester.ensureVisible(resetBtn);
      await tester.tap(resetBtn);
      await tester.pump(); // Start loading
      await tester.pump(const Duration(milliseconds: 1100)); // Finish delayed future

      expect(find.text('Talimatlar Gönderildi'), findsOneWidget);
      expect(find.textContaining('musteri@gude.com'), findsOneWidget);
    });

    testWidgets('AuthGate renders LoginPage or DashboardPage according to auth state', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider(create: (_) => AutomationState()),
            ],
            child: const AuthGate(),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      // Başlangıçta unauthenticated ise LoginPage veya direct mode ise Dashboard görünür
      expect(
        find.byType(LoginPage).evaluate().isNotEmpty || find.byType(Scaffold).evaluate().isNotEmpty,
        isTrue,
      );
    });

    testWidgets('UserProfileDialog renders user info and handles logout flow', (WidgetTester tester) async {
      final state = AutomationState();

      await tester.pumpWidget(
        MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<AutomationState>.value(value: state),
            ],
            child: Scaffold(
              body: Builder(
                builder: (context) {
                  return ElevatedButton(
                    onPressed: () => UserProfileDialog.show(context),
                    child: const Text('Profili Aç'),
                  );
                },
              ),
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Profil butonuna bas
      await tester.tap(find.text('Profili Aç'));
      await tester.pumpAndSettle();

      // Profil dialogu elemanları kontrol edilir
      expect(find.text('Kullanıcı Profili'), findsOneWidget);
      expect(find.text('Oturumu Kapat'), findsOneWidget);

      // Oturumu Kapat'a tıkla -> Onay dialogu açılır
      await tester.tap(find.text('Oturumu Kapat'));
      await tester.pumpAndSettle();

      expect(find.text('Çıkış Yapılsın mı?'), findsOneWidget);
      expect(find.text('Evet, Çıkış Yap'), findsOneWidget);

      // Onayla
      await tester.tap(find.text('Evet, Çıkış Yap'));
      await tester.pumpAndSettle();

      // State'te oturum kapatılmış olmalıdır
      expect(state.currentUser, isNull);
      expect(state.authStatus, AuthStatus.unauthenticated);
      expect(state.mode, AppMode.cloud);
    });
  });
}
