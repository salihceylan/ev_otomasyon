import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/auth/auth_gate.dart';
import 'package:ev_otomasyon/ui/pages/auth/login_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/local_auth'),
      (MethodCall methodCall) async {
        if (methodCall.method == 'isDeviceSupported') return true;
        if (methodCall.method == 'canCheckBiometrics') return true;
        if (methodCall.method == 'getAvailableBiometrics') return <String>['face'];
        if (methodCall.method == 'authenticate') return true;
        return null;
      },
    );
  });

  group('Açılış Ekranı & Dairesel AI Logo Tasarım Testleri', () {
    testWidgets('AuthGate Splash Screen renders AI circuit background and circular logo without overflow', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.resetPhysicalSize);

      final state = AutomationState();
      addTearDown(() => state.dispose());

      await tester.pumpWidget(
        ChangeNotifierProvider<AutomationState>.value(
          value: state,
          child: const MaterialApp(
            home: AuthGate(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      state.setModeForTesting(AppMode.cloud);
      state.setBiometricForTesting(
        isSupported: true,
        isEnabled: false,
        failed: false,
        authStatus: AuthStatus.checking,
      );
      await tester.pump();

      // Başlıklar
      expect(find.text('AHBU OTOMASYON'), findsOneWidget);
      expect(find.text('YAPAY ZEKA DESTEKLİ AKILLI YAŞAM'), findsOneWidget);

      // Dairesel ClipOval logo varlığı
      final clipOvalFinder = find.byType(ClipOval);
      expect(clipOvalFinder, findsWidgets);

      // Arka plan görseli
      final imageFinder = find.byType(Image);
      expect(imageFinder, findsWidgets);

      // Taşma hatası olmamalı
      expect(tester.takeException(), isNull);
    });

    testWidgets('LoginPage renders circular logo and AI branding without overflow', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.resetPhysicalSize);

      final state = AutomationState();
      state.setAuthStatusForTesting(AuthStatus.unauthenticated);

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AutomationState>.value(
            value: state,
            child: const LoginPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Başlık ve slogan
      expect(find.text('AHBU OTOMASYON'), findsOneWidget);
      expect(find.text('Yapay Zeka Destekli Akıllı Yaşam'), findsOneWidget);

      // Logo dairesel ClipOval olmalı
      final clipOvalFinder = find.byType(ClipOval);
      expect(clipOvalFinder, findsWidgets);

      // Form elemanları
      expect(find.text('Giriş Yap'), findsOneWidget);

      // Taşma hatası olmamalı
      expect(tester.takeException(), isNull);
    });
  });
}
