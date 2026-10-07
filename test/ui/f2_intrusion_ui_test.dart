import 'package:ev_otomasyon/models/automation_models.dart';
import 'package:ev_otomasyon/ui/dashboard/apartment_dashboard.dart';
import 'package:ev_otomasyon/ui/widgets/safety_labels.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../models/arm_state_test.dart' show armStateJson, contact;
import '../support/safety_fixtures.dart';
import '../support/support.dart';
import 'e1_helpers.dart';

/// Faz 2 WP-I6 (tasarım F2.B.9): alarm kipi kutucuğu, hırsız alarmı kartı, giriş gecikmesi kartı, "Evden Çıkıyorum"
/// alarm önerisi, geçmiş etiketi.
void main() {
  const dashboard = Scaffold(body: ApartmentDashboard());
  const tall = Size(800, 3600);
  const uid = kSafetyUid;

  Map<String, dynamic> armed(String mode, String st, {List<String> srcs = const <String>[], int? untilUp, int uptime = 3000}) {
    final json = armStateJson(
      arm: <String, dynamic>{
        'mode': mode,
        'st': st,
        'ok': true,
        'until_up': ?untilUp,
        if (st == 'alarm') 'aid': '9f3a11c0-7',
        if (srcs.isNotEmpty) 'srcs': srcs,
      },
      contacts: <Map<String, dynamic>>[contact('d6', 'window'), contact('d5', 'door')],
    );
    json['uptime'] = uptime;
    return json;
  }

  Future<void> flush(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<StateHarness> ready(WidgetTester tester, {String role = 'owner', Map<String, dynamic>? state}) async {
    final h = await pumpReady(
      tester,
      dashboard,
      role: role,
      home: role == 'guest' ? guestHome(hours: 5) : null,
      endpoints: safetyUiEndpoints(),
      size: tall,
    );
    if (state != null) {
      h.mqtt.emitStateJson(state);
      await flush(tester);
    }
    return h;
  }

  Finder inKey(String key, Finder matching) => find.descendant(of: byKeyName(key), matching: matching);

  group('alarm kipi kutucuğu', () {
    testWidgets('kip seçici güvenlik bölümünün başında; eski panoda (arm yok) yok', (tester) async {
      final h = await ready(tester, state: safetyStateJson());
      expect(byKeyName('tile_alarm_mode_$uid'), findsNothing);
      h.mqtt.emitStateJson(armed('off', 'idle'));
      await flush(tester);
      expect(byKeyName('tile_alarm_mode_$uid'), findsOneWidget);
      for (final m in <String>['off', 'home', 'away']) {
        expect(byKeyName('chip_arm_${uid}_$m'), findsOneWidget);
      }
      expect(inKey('tile_alarm_mode_$uid', find.text('Kapalı')), findsOneWidget);
      expect(inKey('tile_alarm_mode_$uid', find.text('Evde')), findsOneWidget);
      expect(inKey('tile_alarm_mode_$uid', find.text('Dışarıda')), findsOneWidget);
      expect(
        tester.getTopLeft(byKeyName('tile_alarm_mode_$uid')).dy,
        lessThan(tester.getTopLeft(byKeyName('card_actuator_a1')).dy),
      );
    });

    testWidgets('kurma onaylı: vazgeç -> komut yok; onay -> POST arm, "Uygulanıyor…" (iyimser değil)', (tester) async {
      final h = await ready(tester, state: armed('off', 'idle'));
      await tester.ensureVisible(byKeyName('chip_arm_${uid}_away'));
      await tester.tap(byKeyName('chip_arm_${uid}_away'));
      await tester.pump();
      await tester.tap(byKeyName('btn_arm_cancel'));
      await flush(tester);
      expect(h.cloud.armCalls, isEmpty);

      await tester.tap(byKeyName('chip_arm_${uid}_away'));
      await tester.pump();
      await tester.tap(byKeyName('btn_arm_confirm'));
      await flush(tester);
      expect(h.cloud.armCalls.single.mode, 'away');
      expect(byKeyName('arm_pending_$uid'), findsOneWidget);
      expect(inKey('arm_pending_$uid', find.text('Uygulanıyor…')), findsOneWidget);
    });

    testWidgets('çıkış gecikmesinde geri sayım ("Çıkış için 45 sn")', (tester) async {
      await ready(tester, state: armed('away', 'exit', untilUp: 3045, uptime: 3000));
      expect(inKey('arm_countdown_$uid', find.text('Çıkış için 45 sn')), findsOneWidget);
    });

    testWidgets('misafir: seçici yok, yalnız kip metni', (tester) async {
      await ready(tester, role: 'guest', state: armed('home', 'idle'));
      expect(byKeyName('tile_alarm_mode_$uid'), findsOneWidget);
      expect(byKeyName('chip_arm_${uid}_off'), findsNothing);
      expect(inKey('tile_alarm_mode_$uid', find.textContaining('Evde kurulu')), findsOneWidget);
    });
  });

  group('hırsız alarmı kartları', () {
    testWidgets('alarm: panonun üstünde kart, tetikleyen sensör adı, "Alarmı Çöz" onaylı çözme', (tester) async {
      final h = await ready(tester, state: armed('away', 'alarm', srcs: <String>['d6']));
      final card = byKeyName('card_intrusion_$uid');
      expect(card, findsOneWidget);
      expect(inKey('card_intrusion_$uid', find.text('Hırsız alarmı')), findsOneWidget);
      expect(inKey('card_intrusion_$uid', find.textContaining('Giriş 6')), findsOneWidget);
      expect(tester.getTopLeft(card).dy, lessThan(tester.getTopLeft(byKeyName('home_hero')).dy));
      await tester.tap(byKeyName('btn_disarm_$uid'));
      await tester.pump();
      await tester.tap(byKeyName('btn_arm_confirm'));
      await flush(tester);
      expect(h.cloud.armCalls.single.mode, 'off');
    });

    testWidgets('tehlike kartından SONRA gelir', (tester) async {
      final json = armed('away', 'alarm', srcs: <String>['d6']);
      final hazard = safetyStateJson(zoneSt: 'latched', sensorActive: true);
      json['safety'] = <String, dynamic>{...(hazard['safety'] as Map<String, dynamic>), 'arm': (json['safety'] as Map)['arm']};
      await ready(tester, state: json);
      expect(
        tester.getTopLeft(byKeyName('card_critical_alarm_${uid}_1')).dy,
        lessThan(tester.getTopLeft(byKeyName('card_intrusion_$uid')).dy),
      );
    });

    testWidgets('giriş gecikmesi bilgi kartı', (tester) async {
      await ready(tester, state: armed('away', 'entry', untilUp: 3023, uptime: 3000));
      expect(
        inKey('card_intrusion_entry_$uid', find.text('Giriş gecikmesi: 23 sn içinde alarmı çözün.')),
        findsOneWidget,
      );
    });

    testWidgets('misafir: çöz düğmesi yok', (tester) async {
      await ready(tester, role: 'guest', state: armed('away', 'alarm', srcs: <String>['d6']));
      expect(byKeyName('card_intrusion_$uid'), findsOneWidget);
      expect(byKeyName('btn_disarm_$uid'), findsNothing);
    });
  });

  group('"Evden Çıkıyorum" alarm önerisi', () {
    testWidgets('caps intrusion + yetki: son adımda öneri; hayır -> komut dizisi aynen, kurma yok', (tester) async {
      final h = await ready(tester, state: armed('off', 'idle'));
      await tester.ensureVisible(byKeyName('card_scenario_leaving'));
      await tester.tap(byKeyName('card_scenario_leaving'));
      await flush(tester);
      expect(find.text('Alarmı dışarıda kip ile kurayım mı?'), findsOneWidget);
      final commands = List<Map<String, dynamic>>.of(h.cloud.sentCommands);
      await tester.tap(byKeyName('btn_leaving_arm_cancel'));
      await flush(tester);
      expect(h.cloud.armCalls, isEmpty);
      expect(h.cloud.sentCommands, commands);
    });

    testWidgets('evet -> alarm dışarıda kurulur', (tester) async {
      final h = await ready(tester, state: armed('off', 'idle'));
      await tester.ensureVisible(byKeyName('card_scenario_leaving'));
      await tester.tap(byKeyName('card_scenario_leaving'));
      await flush(tester);
      await tester.tap(byKeyName('btn_leaving_arm_confirm'));
      await flush(tester);
      expect(h.cloud.armCalls.single.mode, 'away');
    });

    testWidgets('caps intrusion yoksa öneri yok (bugünkü davranış)', (tester) async {
      await ready(tester, state: safetyStateJson());
      await tester.ensureVisible(byKeyName('card_scenario_leaving'));
      await tester.tap(byKeyName('card_scenario_leaving'));
      await flush(tester);
      expect(find.text('Alarmı dışarıda kip ile kurayım mı?'), findsNothing);
    });
  });

  test('geçmiş etiketleri: intrusion -> "Hırsız alarmı"; LAN olayları', () {
    expect(safetyKindTitle('intrusion'), 'Hırsız alarmı');
    expect(deviceEventLabel(const DeviceEventRecord(eid: 'x-1', type: 'intrusion_alarm')), 'Hırsız alarmı');
    expect(deviceEventLabel(const DeviceEventRecord(eid: 'x-2', type: 'intrusion_cleared')), 'Hırsız alarmı çözüldü');
    expect(deviceEventLabel(const DeviceEventRecord(eid: 'x-3', type: 'arm_changed')), 'Alarm kipi değişti');
  });
}
