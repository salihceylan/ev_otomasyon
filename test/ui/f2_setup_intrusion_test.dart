import 'package:ev_otomasyon/ui/pages/service_setup/logic/safety_assignment.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_steps.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'f_flow_support.dart';
import 'f_support.dart';
import 'f_widget_support.dart';

/// Faz 2 WP-I6 (tasarım F2.B.1, F2.B.3, F2.B.9 sihirbaz): kapı/pencere/hareket için "Giriş yolu" ve "Yalnız dışarıda
/// kipte" anahtarları, `arm_key` rolü + uyarı, çıkış/giriş gecikmesi. Yeni bitler yalnız `caps` `intrusion` varken yazılır.
void main() {
  group('saf mantık', () {
    InputAssignment input(InputRole role, {bool? entry, bool? awayOnly}) =>
        InputAssignment(src: 'di', index: 5, role: role, normallyClosed: true, entry: entry, awayOnly: awayOnly);

    test('bayraklar yalnız intrusion desteğinde; varsayılanlar kapı giriş yolu, hareket yalnız dışarıda', () {
      expect(safetySensorItem(input(InputRole.door)).containsKey('flags'), isFalse, reason: 'v1.2.0 panoya yeni bit yok');
      expect(safetySensorItem(input(InputRole.door), intrusion: true)['flags'], 0x09);
      expect(safetySensorItem(input(InputRole.window), intrusion: true)['flags'], 0x01);
      expect(safetySensorItem(input(InputRole.motion), intrusion: true)['flags'], 0x11);
      expect(safetySensorItem(input(InputRole.window, entry: true), intrusion: true)['flags'], 0x09);
      expect(safetySensorItem(input(InputRole.door, entry: false, awayOnly: true), intrusion: true)['flags'], 0x11);
      expect(safetySensorItem(input(InputRole.water), intrusion: true).containsKey('flags'), isFalse);
    });

    test('kayıt ve panodan okuma: bayraklar korunur', () {
      final a = input(InputRole.window, entry: true, awayOnly: true);
      expect(InputAssignment.fromJson(a.toJson()), a);
      final board = InputAssignment.fromBoard(<String, dynamic>{'id': 'd5', 'kind': 'window', 'zone': 1, 'flags': 0x11})!;
      expect(board.effectiveEntry, isFalse);
      expect(board.effectiveAwayOnly, isTrue);
      expect(InputAssignment.fromBoard(<String, dynamic>{'id': 'd5', 'kind': 'arm_key', 'zone': 1})!.role, InputRole.armKey);
    });

    test('gecikmeler: değişince tek intrusion yaması; aynıysa ya da desteklenmiyorsa yok', () {
      List<Map<String, dynamic>> patches({bool intrusion = true, int exit = 60, int entry = 30}) => buildSafetyPatches(
            current: <String, dynamic>{
              'rev': 3,
              'intrusion': <String, dynamic>{'exit_s': 45, 'entry_s': 30},
            },
            channels: const <int, ChannelAssignment>{},
            inputs: const <InputAssignment>[],
            intrusion: intrusion,
            intrusionDelays: (exit: exit, entry: entry),
          );
      expect(patches(), <Map<String, dynamic>>[
        <String, dynamic>{
          'set': <String, dynamic>{
            'intrusion': <String, dynamic>{'exit_s': 60, 'entry_s': 30},
          },
        },
      ]);
      expect(patches(exit: 45), isEmpty);
      expect(patches(intrusion: false), isEmpty);
    });

    // Faz 2 incelemesi RV-E3: anahtarlı kontak yalnız NC (kurulu konumda kontak açık): kablo kesilince kurulu okunur, alarm çözülmez.
    test('arm_key yalnız NC: rol seçilince NC olur, NO plan engellenir, yama active_open 1 (RV-E3)', () {
      expect(InputRole.armKey.requiresNc, isTrue);
      const plain = InputAssignment(src: 'di', index: 5);
      final k = plain.copyWith(role: InputRole.armKey);
      expect(k.normallyClosed, isTrue);
      expect(safetySensorItem(k, intrusion: true)['active_open'], 1);
      const no = InputAssignment(src: 'di', index: 5, role: InputRole.armKey);
      final issues = validateSafetyPlan(const <int, ChannelAssignment>{}, const <InputAssignment>[no]);
      expect(issues.any((i) => i.blocking && i.target == 'input:d5' && i.message.contains('NC')), isTrue);
    });
  });

  group('arayüz', () {
    Future<ServiceHarness> open(WidgetTester tester, {bool intrusion = true}) async {
      final env = await serviceHarness(flush: () async {});
      addTearDown(env.dispose);
      env.device.safetyCaps = true;
      env.device.intrusionCaps = intrusion;
      await openWizardResumedAt(tester, env, SetupSteps.relays, size: const Size(900, 7000));
      await pumpUntil(tester, env, () => present('card_relay_5'), reason: 'röle listesi yüklenmedi');
      return env;
    }

    Finder inKey(String key, Finder matching) => find.descendant(of: find.byKey(Key(key)), matching: matching);

    Future<void> pickRole(WidgetTester tester, String input, String label) async {
      await tester.ensureVisible(find.byKey(Key('dd_role_$input')));
      await tester.tap(find.byKey(Key('dd_role_$input')));
      await settle(tester);
      await tester.tap(find.text(label).last);
      await settle(tester);
    }

    testWidgets('intrusion yoksa: anahtar rolü ve hırsız ayarları görünmez (bugünkü sihirbaz)', (tester) async {
      await open(tester, intrusion: false);
      await tester.tap(find.byKey(const Key('dd_role_d1')));
      await settle(tester);
      expect(find.text('Alarm anahtarı (anahtarlı kontak)'), findsNothing);
      await tester.tap(find.text('Kapı kontağı').last);
      await settle(tester);
      expect(find.byKey(const Key('switch_entry_d1')), findsNothing);
      expect(find.byKey(const Key('field_exit_delay')), findsNothing);
    });

    testWidgets('kapı: giriş yolu açık, yalnız dışarıda kapalı (varsayılan); arm_key uyarısı; gecikme alanları', (tester) async {
      final env = await open(tester);
      await pickRole(tester, 'd1', 'Kapı kontağı');
      expect(find.byKey(const Key('switch_entry_d1')), findsOneWidget);
      expect(find.byKey(const Key('switch_awayonly_d1')), findsOneWidget);
      expect(tester.widget<SetupCheckTile>(find.byKey(const Key('switch_entry_d1'))).value, isTrue);
      expect(tester.widget<SetupCheckTile>(find.byKey(const Key('switch_awayonly_d1'))).value, isFalse);

      await pickRole(tester, 'd2', 'Alarm anahtarı (anahtarlı kontak)');
      expect(
        inKey('note_arm_key_d2', find.textContaining('Bu giriş alarmı çözer. Yalnız anahtarlı ya da korumalı bir kontak bağlayın.')),
        findsOneWidget,
      );
      // RV-E3: NC zorunlu notu anahtar notunda; dedektör kablolama notu (gaz/duman) gösterilmez
      expect(inKey('note_arm_key_d2', find.textContaining('NC')), findsOneWidget);
      expect(find.byKey(const Key('note_detector_d2')), findsNothing);
      expect(find.byKey(const Key('field_exit_delay')), findsOneWidget);
      expect(find.byKey(const Key('field_entry_delay')), findsOneWidget);

      await typeKey(tester, 'field_exit_delay', '60');
      await tapKey(tester, 'btn_save_safety');
      await pumpUntil(tester, env, () => env.device.savedSafetyConfig?['intrusion'] != null, reason: 'gecikme yazılmadı');
      expect(env.device.savedSafetyConfig!['intrusion'], <String, dynamic>{'exit_s': 60, 'entry_s': 30});
      final sensors = (env.device.savedSafetyConfig!['sensors'] as List).cast<Map<String, dynamic>>();
      expect(sensors.firstWhere((s) => s['id'] == 'd1')['flags'], 0x09);
      expect(sensors.firstWhere((s) => s['id'] == 'd2')['kind'], 'arm_key');
      expect(sensors.firstWhere((s) => s['id'] == 'd2')['active_open'], 1, reason: 'anahtarlı kontak NC yazılır (RV-E3)');
    });
  });
}
