import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ev_otomasyon/models/automation_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/device_settings_page.dart';
import 'package:ev_otomasyon/ui/pages/dashboard_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({'saved_app_mode': 'cloud'});
  });

  group('ADIM 17: Gece Bildirimi & Yazılımsal Çocuk Kilidi Tests', () {
    test('DeviceStatus.fromJson parses child_lock correctly', () {
      final jsonWithLock = {
        'device_name': 'AHBU-ESP32S3-TEST',
        'ip': '192.168.1.100',
        'wifi_connected': true,
        'wifi_sta_ssid': 'HomeNet',
        'wifi_sta_ip': '192.168.1.100',
        'wifi_sta_rssi': -55,
        'uptime_sec': 3600,
        'relays': [
          {'index': 0, 'name': 'Mutfak Spot', 'state': true, 'is_light': true},
          {'index': 1, 'name': 'Kombi', 'state': false, 'is_light': false},
        ],
        'dis': [
          {'index': 0, 'raw_state': 0, 'is_inverted': true},
        ],
        'shutters': [],
        'child_lock': true,
      };

      final statusLocked = DeviceStatus.fromJson(jsonWithLock);
      expect(statusLocked.childLock, isTrue);

      final jsonWithoutLock = Map<String, dynamic>.from(jsonWithLock)..['child_lock'] = false;
      final statusUnlocked = DeviceStatus.fromJson(jsonWithoutLock);
      expect(statusUnlocked.childLock, isFalse);
    });

    testWidgets('AutomationState childLock and openLightsCount defaults and setters', (tester) async {
      final state = AutomationState();
      addTearDown(() => state.dispose());

      expect(state.childLock, isFalse);
      expect(state.openLightsCount, equals(0));

      await state.toggleChildLock(true);
      expect(state.childLock, isTrue);

      await state.toggleChildLock(false);
      expect(state.childLock, isFalse);

      await tester.pump(const Duration(milliseconds: 100));
    });

    testWidgets('DeviceSettingsPage renders Child Lock and Peace Notification cards without overflow', (tester) async {
      tester.view.physicalSize = const Size(600, 1200);
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

      // Çocuk kilidi kartı ve metinleri bulunmalı
      expect(find.text('Yazılımsal Çocuk Kilidi'), findsOneWidget);
      expect(find.textContaining('fiziksel yaylı anahtarlara basılsa dahi'), findsOneWidget);
      expect(find.text('Devre Dışı (Anahtarlar Serbest)'), findsOneWidget);

      // Gece Huzur Bildirimi kartı ve metinleri bulunmalı
      expect(find.text('Gece Huzur Bildirimi'), findsOneWidget);
      expect(find.textContaining('Her gece belirlenen saatte açık kalan lamba'), findsOneWidget);
      expect(find.text('Bildirim Saati:'), findsOneWidget);
      expect(find.text('Saat Seç'), findsOneWidget);
    });

    testWidgets('DeviceSettingsPage Child Lock toggles and updates UI state', (tester) async {
      tester.view.physicalSize = const Size(600, 1200);
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

      // Switch'i bul ve tıkla
      final switches = find.byType(Switch);
      expect(switches, findsAtLeastNWidgets(2));

      // Çocuk kilidi switch'ini aç
      await tester.tap(switches.first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(state.childLock, isTrue);
      expect(find.text('Aktif (Duvardaki Anahtarlar Kilitli)'), findsOneWidget);
    });

    testWidgets('DashboardPage displays Child Lock pill when active', (tester) async {
      tester.view.physicalSize = const Size(600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final state = AutomationState();
      addTearDown(() => state.dispose());

      await state.toggleChildLock(true);

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AutomationState>.value(
            value: state,
            child: const DashboardPage(),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // Çocuk kilidi hapı görünmeli
      expect(find.text('Çocuk Kilidi Aktif'), findsOneWidget);
    });

    testWidgets('DashboardPage displays Peace Banner when lights are open', (tester) async {
      tester.view.physicalSize = const Size(600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final state = AutomationState();
      addTearDown(() => state.dispose());

      await tester.pump(const Duration(milliseconds: 100));

      // Bulut modunda iki açık lamba tanımla
      state.setModeForTesting(AppMode.cloud);
      state.setCloudEndpointsForTesting([
        EndpointModel(
          id: 1,
          homeId: 1,
          name: 'Salon Avize',
          room: 'Salon',
          endpointType: 'light',
          currentState: true,
          channel: 0,
        ),
        EndpointModel(
          id: 2,
          homeId: 1,
          name: 'Koridor Spot',
          room: 'Antre',
          endpointType: 'light',
          currentState: true,
          channel: 1,
        ),
      ]);

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AutomationState>.value(
            value: state,
            child: const DashboardPage(),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // Huzur Modu bannerı ve Hepsini Kapat butonu görünmeli
      expect(find.text('Huzur Modu / Gece Kontrolü'), findsOneWidget);
      expect(find.text('2 lamba açık kaldı.'), findsOneWidget);
      expect(find.text('Hepsini Kapat'), findsOneWidget);
    });
  });
}
