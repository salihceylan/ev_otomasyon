import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/auth/auth_gate.dart';
import 'package:ev_otomasyon/ui/pages/device_settings_page.dart';
import 'package:ev_otomasyon/ui/widgets/biometric_prompt_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({'saved_app_mode': 'cloud'});
    FlutterSecureStorage.setMockInitialValues({});

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/local_auth'),
      (MethodCall methodCall) async {
        if (methodCall.method == 'getAvailableBiometrics') {
          return <String>['face'];
        }
        if (methodCall.method == 'authenticate') {
          return true;
        }
        if (methodCall.method == 'isDeviceSupported') {
          return true;
        }
        if (methodCall.method == 'canCheckBiometrics') {
          return true;
        }
        return null;
      },
    );
  });

  group('ADIM 19: Biyometrik Güvenlik & Anlık Giriş Deneyimi Tests', () {
    testWidgets('AutomationState biometric getters, setters and toggle logic', (tester) async {
      final state = AutomationState();
      addTearDown(() => state.dispose());

      expect(state.isBiometricEnabled, isFalse);

      state.setBiometricForTesting(
        isSupported: true,
        isEnabled: true,
        label: 'Face ID',
      );

      expect(state.isBiometricSupported, isTrue);
      expect(state.isBiometricEnabled, isTrue);
      expect(state.biometricLabel, equals('Face ID'));

      await state.toggleBiometric(false);
      expect(state.isBiometricEnabled, isFalse);
    });

    testWidgets('BiometricPromptDialog renders title, hardware notice and buttons without overflow', (tester) async {
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
              body: BiometricPromptDialog(biometricLabel: 'Face ID'),
            ),
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Face ID Kullanılsın mı?'), findsOneWidget);
      expect(find.text('Daha Sonra'), findsOneWidget);
      expect(find.text('Evet, Etkinleştir'), findsOneWidget);
      expect(find.textContaining('Keystore/Keychain'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('DeviceSettingsPage displays Biometric Login card with switch without overflow', (tester) async {
      tester.view.physicalSize = const Size(600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final state = AutomationState();
      addTearDown(() => state.dispose());

      state.setModeForTesting(AppMode.cloud);
      state.setBiometricForTesting(
        isSupported: true,
        isEnabled: true,
        label: 'Face ID',
      );

      await tester.pumpWidget(
        ChangeNotifierProvider<AutomationState>.value(
          value: state,
          child: const MaterialApp(
            home: DeviceSettingsPage(),
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Face ID Girişi'), findsOneWidget);
      expect(find.text('Açılışta Face ID ile anında giriş yapın'), findsOneWidget);
      expect(find.byType(Switch), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('AuthGate renders biometric failed retry options without overflow', (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
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

      await tester.pumpAndSettle();

      state.setModeForTesting(AppMode.cloud);
      state.setBiometricForTesting(
        isSupported: true,
        isEnabled: true,
        failed: true,
        label: 'Face ID',
        authStatus: AuthStatus.checking,
      );

      await tester.pump();

      expect(find.text('Face ID doğrulaması tamamlanamadı.'), findsOneWidget);
      expect(find.text('Face ID ile Aç'), findsOneWidget);
      expect(find.text('Şifre ile Giriş Yap'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
