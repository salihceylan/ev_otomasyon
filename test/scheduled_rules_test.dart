import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ev_otomasyon/models/scheduled_rule_model.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/scheduled_rules_page.dart';
import 'package:ev_otomasyon/ui/pages/device_settings_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({'saved_app_mode': 'cloud'});
  });

  group('ADIM 18: Zamanlı Otomasyon Kuralları (Scheduled Rules) Tests', () {
    test('ScheduledRule model serialization and getters work correctly', () {
      final json = {
        'id': 101,
        'home_id': 1,
        'device_id': null,
        'channel': 0,
        'channel_type': 'shutter',
        'action': 'close',
        'hour': 22,
        'minute': 30,
        'days_of_week': [1, 2, 3, 4, 5],
        'label': 'Salon Panjur Gece Kapanışı',
        'enabled': true,
        'created_by_name': 'Salih Ceylan',
      };

      final rule = ScheduledRule.fromJson(json);
      expect(rule.id, equals(101));
      expect(rule.timeString, equals('22:30'));
      expect(rule.actionLabel, equals('Kapat'));
      expect(rule.channelLabel, equals('Salon Panjur Gece Kapanışı'));
      expect(rule.daysShortString, equals('Pzt Sal Çar Per Cum'));
      expect(rule.actionIcon, equals(Icons.compress));

      final serialized = rule.toJson();
      expect(serialized['action'], equals('close'));
      expect(serialized['hour'], equals(22));
      expect(serialized['minute'], equals(30));

      final allDaysRule = rule.copyWith(daysOfWeek: [0, 1, 2, 3, 4, 5, 6]);
      expect(allDaysRule.daysShortString, equals('Her gün'));

      final emptyDaysRule = rule.copyWith(daysOfWeek: []);
      expect(emptyDaysRule.daysShortString, equals('Gün seçilmedi'));
    });

    test('ScheduledRule relay model and action getters', () {
      final relayJson = {
        'id': 202,
        'home_id': 1,
        'channel': 1,
        'channel_type': 'relay',
        'action': 'on',
        'hour': 7,
        'minute': 5,
        'days_of_week': [0, 6],
        'label': null,
        'enabled': false,
      };

      final rule = ScheduledRule.fromJson(relayJson);
      expect(rule.timeString, equals('07:05'));
      expect(rule.actionLabel, equals('Aç'));
      expect(rule.channelLabel, equals('Röle 2'));
      expect(rule.actionIcon, equals(Icons.lightbulb));
      expect(rule.enabled, isFalse);
    });

    testWidgets('DeviceSettingsPage displays Scheduled Rules card without overflow', (tester) async {
      tester.view.physicalSize = const Size(600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final state = AutomationState();
      addTearDown(() => state.dispose());

      state.setModeForTesting(AppMode.cloud);
      state.setScheduledRulesForTesting([
        const ScheduledRule(
          id: 1,
          homeId: 1,
          channel: 0,
          channelType: 'shutter',
          action: 'close',
          hour: 22,
          minute: 0,
          daysOfWeek: [0, 1, 2, 3, 4, 5, 6],
          label: 'Otomatik Panjur Kapat',
          enabled: true,
        ),
      ]);

      await tester.pumpWidget(
        ChangeNotifierProvider<AutomationState>.value(
          value: state,
          child: const MaterialApp(
            home: DeviceSettingsPage(),
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Zamanlı Otomasyon Kuralları'), findsOneWidget);
      expect(find.text('1 aktif / 1 kural'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('ScheduledRulesPage renders empty state and list without overflow', (tester) async {
      tester.view.physicalSize = const Size(600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final state = AutomationState();
      addTearDown(() => state.dispose());

      state.setModeForTesting(AppMode.cloud);
      state.setScheduledRulesForTesting([]);

      await tester.pumpWidget(
        ChangeNotifierProvider<AutomationState>.value(
          value: state,
          child: const MaterialApp(
            home: ScheduledRulesPage(),
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Zamanlı Kurallar'), findsOneWidget);
      expect(find.text('Henüz zamanlı kural yok'), findsOneWidget);

      // Now inject rules and verify cards
      state.setScheduledRulesForTesting([
        const ScheduledRule(
          id: 10,
          homeId: 1,
          channel: 0,
          channelType: 'shutter',
          action: 'close',
          hour: 22,
          minute: 30,
          daysOfWeek: [1, 2, 3, 4, 5],
          label: 'Salon Panjur',
          enabled: true,
        ),
        const ScheduledRule(
          id: 11,
          homeId: 1,
          channel: 1,
          channelType: 'relay',
          action: 'off',
          hour: 23,
          minute: 0,
          daysOfWeek: [0, 1, 2, 3, 4, 5, 6],
          label: 'Bahçe Aydınlatma',
          enabled: false,
        ),
      ]);

      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Salon Panjur'), findsOneWidget);
      expect(find.text('Bahçe Aydınlatma'), findsOneWidget);
      expect(find.text('22:30'), findsOneWidget);
      expect(find.text('23:00'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

