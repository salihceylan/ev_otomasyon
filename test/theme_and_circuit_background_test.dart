import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/theme/app_theme.dart';
import 'package:ev_otomasyon/ui/widgets/circuit_background.dart';
import 'package:ev_otomasyon/ui/pages/device_settings_page.dart';
import 'package:ev_otomasyon/ui/widgets/user_profile_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({'saved_app_mode': 'cloud'});
  });

  group('Tema & Elektronik Devre Arka Planı (CircuitBackground) Tests', () {
    testWidgets('AppTheme defines light and dark themes with correct brightness and palettes', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          home: const SizedBox(),
        ),
      );
      await tester.pump();

      final dark = AppTheme.darkTheme;
      final light = AppTheme.lightTheme;

      expect(dark.brightness, equals(Brightness.dark));
      expect(light.brightness, equals(Brightness.light));

      expect(dark.colorScheme.primary, equals(AppTheme.primaryBlue));
      expect(light.colorScheme.primary, equals(AppTheme.primaryBlue));
    });

    testWidgets('AutomationState defaults to ThemeMode.dark and persists user selection', (tester) async {
      final state = AutomationState();
      addTearDown(() => state.dispose());

      // Varsayılan karanlık mod olmalı
      expect(state.themeMode, equals(ThemeMode.dark));

      // Aydınlık moda geç
      await state.setThemeMode(ThemeMode.light);
      expect(state.themeMode, equals(ThemeMode.light));

      // Sistem temasına geç
      await state.setThemeMode(ThemeMode.system);
      expect(state.themeMode, equals(ThemeMode.system));

      await tester.pump(const Duration(milliseconds: 100));
    });

    testWidgets('CircuitBackground renders custom circuit board painter without error', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CircuitBackground(
              child: Center(
                child: Text('AHBU Elektronik Devre'),
              ),
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(CircuitBackground), findsOneWidget);
      expect(find.byType(CustomPaint), findsWidgets);
      expect(find.text('AHBU Elektronik Devre'), findsOneWidget);
    });

    testWidgets('DeviceSettingsPage displays Theme Selector card and switches modes without overflow', (tester) async {
      tester.view.physicalSize = const Size(600, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

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

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // Görünüm & Tema Modu kartı görünür olmalı
      expect(find.text('Görünüm & Tema Modu'), findsOneWidget);
      expect(find.text('Karanlık Mod (Varsayılan)'), findsOneWidget);
      expect(find.text('Koyu'), findsOneWidget);
      expect(find.text('Açık'), findsOneWidget);
      expect(find.text('Sistem'), findsOneWidget);

      // 'Açık' butonuna tıkla
      await tester.ensureVisible(find.text('Açık'));
      await tester.tap(find.text('Açık'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(state.themeMode, equals(ThemeMode.light));
      expect(find.text('Aydınlık Mod'), findsOneWidget);

      // 'Koyu' butonuna tıkla
      await tester.ensureVisible(find.text('Koyu'));
      await tester.tap(find.text('Koyu'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(state.themeMode, equals(ThemeMode.dark));
      expect(find.text('Karanlık Mod (Varsayılan)'), findsOneWidget);
    });

    testWidgets('UserProfileDialog includes quick theme switch button', (tester) async {
      tester.view.physicalSize = const Size(600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final state = AutomationState();
      addTearDown(() => state.dispose());

      await tester.pumpWidget(
        ChangeNotifierProvider<AutomationState>.value(
          value: state,
          child: const MaterialApp(
            home: Scaffold(
              body: UserProfileDialog(),
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // Hızlı tema geçiş butonu bulunmalı
      expect(find.text('Aydınlık Moda Geç'), findsOneWidget);

      // Butona dokun ve aydınlık moda geç
      await tester.tap(find.text('Aydınlık Moda Geç'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(state.themeMode, equals(ThemeMode.light));
      expect(find.text('Karanlık Moda Geç'), findsOneWidget);
    });
  });
}
