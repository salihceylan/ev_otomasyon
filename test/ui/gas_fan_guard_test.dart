import 'package:ev_otomasyon/models/automation_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/dashboard/apartment_dashboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/safety_fixtures.dart';
import '../support/support.dart';
import 'e1_helpers.dart';

/// guvenlik-7: gaz alarmı sürerken çalışan havalandırma fanını yalnız alarm onay yetkisi olan (ev sahibi / üyeler)
/// durdurabilir; durdurmak onay diyaloğu ister. Misafire anahtar çizilmez; komut ağa çıkmadan reddedilir (sunucu da
/// 403 FORBIDDEN döner).
void main() {
  const dashboard = Scaffold(body: ApartmentDashboard());
  const tall = Size(800, 3200);

  Map<String, dynamic> gasWithFan({bool fanOn = true, String zoneSt = 'latched'}) {
    final base = safetyStateJson(zoneSt: zoneSt, valvePos: 'closed');
    base['actuators'] = <Map<String, dynamic>>[
      ...(base['actuators'] as List).cast<Map<String, dynamic>>(),
      <String, dynamic>{'id': 'a4', 'relay': 10, 'kind': 'fan', 'zones': <int>[1], 'on': fanOn},
    ];
    base['relays'] = <Map<String, dynamic>>[
      ...(base['relays'] as List).cast<Map<String, dynamic>>(),
      <String, dynamic>{'id': 10, 'name': 'Fan', 'type': 'light', 'state': fanOn, 'act': 'fan'},
    ];
    base['sensors'] = <Map<String, dynamic>>[
      <String, dynamic>{'id': 'g1', 'src': 'di', 'kind': 'gas', 'zone': 1, 'active': true, 'ok': true},
    ];
    final safety = base['safety'] as Map<String, dynamic>;
    safety['zones'] = <Map<String, dynamic>>[
      for (final z in (safety['zones'] as List).cast<Map<String, dynamic>>())
        <String, dynamic>{...z, 'kind': 'gas', 'srcs': <String>['g1']},
    ];
    return base;
  }

  Future<StateHarness> ready(WidgetTester tester, {HomeModel? home}) async {
    final h = await pumpReady(tester, dashboard, home: home, endpoints: safetyUiEndpoints(), size: tall);
    h.mqtt.emitStateJson(gasWithFan());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    return h;
  }

  testWidgets('ev sahibi: anahtar var; kapatmak onay ister ("Gaz alarmı sürüyor; havalandırma durdurulsun mu?")',
      (tester) async {
    final h = await ready(tester);
    final sw = find.byKey(const Key('switch_actuator_a4'));
    expect(sw, findsOneWidget);
    await tester.ensureVisible(sw);
    await tester.tap(sw);
    await tester.pump();
    expect(find.text('Gaz alarmı sürüyor; havalandırma durdurulsun mu?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('btn_safety_cancel')));
    await tester.pump();
    expect(h.cloud.actuatorCalls, isEmpty, reason: 'vazgeçildi');

    await tester.tap(sw);
    await tester.pump();
    await tester.tap(find.byKey(const Key('btn_safety_confirm')));
    await tester.pump();
    await tester.pump();
    expect(h.cloud.actuatorCalls.single.to, 'off');
  });

  testWidgets('misafir: gaz alarmında çalışan fanın anahtarı çizilmez', (tester) async {
    await ready(tester, home: guestHome(hours: 5));
    expect(find.byKey(const Key('card_actuator_a4')), findsOneWidget);
    expect(find.byKey(const Key('switch_actuator_a4')), findsNothing);
  });

  test('misafirin fan kapatma komutu gaz alarmında ağa çıkmadan reddedilir', () async {
    final h = await readyHarness(
      home: HomeModel(
        id: kHomeA,
        name: 'Misafir Evi',
        role: 'guest',
        mqttTopicId: 'h_test',
        guestValidFrom: kTestNow.subtract(const Duration(hours: 1)),
        guestValidUntil: kTestNow.add(const Duration(hours: 5)),
      ),
      endpoints: safetyUiEndpoints(),
    );
    addTearDown(h.dispose);
    final failures = <CommandFailure>[];
    h.state.commandFailures.listen(failures.add);
    h.mqtt.emitStateJson(gasWithFan());
    await pumpEventQueue();
    final fan = h.state.actuatorItems.firstWhere((a) => a.kind == ActuatorKind.fan);
    expect(await h.state.setActuatorOn(fan, false), isFalse);
    await pumpEventQueue();
    expect(h.cloud.actuatorCalls, isEmpty);
    expect(failures.single.message, 'Gaz alarmı sürerken havalandırmayı yalnız ev sahibi/üyeleri durdurabilir.');

    // Alarm yokken misafir (güvenli yön) kapatabilir.
    h.mqtt.emitStateJson(gasWithFan(zoneSt: 'normal'));
    await pumpEventQueue();
    final idle = h.state.actuatorItems.firstWhere((a) => a.kind == ActuatorKind.fan);
    expect(await h.state.setActuatorOn(idle, false), isTrue);
  });
}
