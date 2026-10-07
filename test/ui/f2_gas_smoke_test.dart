import 'package:ev_otomasyon/services/api_exception.dart';
import 'package:ev_otomasyon/services/ev_cloud_api_service.dart';
import 'package:ev_otomasyon/ui/dashboard/apartment_dashboard.dart';
import 'package:ev_otomasyon/utils/friendly_error.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/safety_fixtures.dart';
import '../support/support.dart';
import 'e1_helpers.dart';

/// Faz 2 WP-G2 (tasarım F2.A.3-A.6): gaz/duman kartı talimatları, gaz vanası satırı, fan satırı, gaz alarmında
/// anahtarlama onayı ve `HAZARD_ACTIVE` metni.
Map<String, dynamic> hazardStateJson({String kind = 'gas', String zoneSt = 'latched', bool fanOn = false}) {
  final base = safetyStateJson(zoneSt: zoneSt, valvePos: 'closed', valveFb: true);
  final zones = ((base['safety'] as Map<String, dynamic>)['zones'] as List).cast<Map<String, dynamic>>();
  return <String, dynamic>{
    ...base,
    'sensors': <Map<String, dynamic>>[
      ...(base['sensors'] as List).cast<Map<String, dynamic>>(),
      <String, dynamic>{'id': 'd4', 'src': 'di', 'kind': kind, 'zone': 1, 'active': true, 'ok': true},
    ],
    'actuators': <Map<String, dynamic>>[
      ...(base['actuators'] as List).cast<Map<String, dynamic>>(),
      <String, dynamic>{'id': 'a4', 'relay': 10, 'kind': 'fan', 'zones': <int>[1], 'on': fanOn},
    ],
    'safety': <String, dynamic>{
      ...(base['safety'] as Map<String, dynamic>),
      'zones': <Map<String, dynamic>>[
        <String, dynamic>{...zones.first, 'kind': kind, 'srcs': <String>['d4']},
      ],
    },
    'cfg': <String, dynamic>{
      'safety': <String, dynamic>{'rev': 5, 'crc': 'abcd1234'},
    },
  };
}

Map<String, dynamic> hazardConfig({bool exproof = false}) => <String, dynamic>{
      'rev': 5,
      'crc': 'abcd1234',
      'sensors': <Map<String, dynamic>>[
        <String, dynamic>{'id': 'd4', 'kind': 'gas', 'zone': 1, 'name': 'Mutfak dedektörü'},
      ],
      'actuators': <Map<String, dynamic>>[
        <String, dynamic>{'id': 'a4', 'relay': 10, 'kind': 'fan', 'zones': <int>[1], 'exproof': exproof, 'name': 'Aspiratör'},
      ],
    };

void main() {
  const dashboard = Scaffold(body: ApartmentDashboard());
  const tall = Size(800, 3200);
  const cardKey = 'card_critical_alarm_${kSafetyUid}_1';

  Future<void> flush(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<StateHarness> ready(WidgetTester tester, {Map<String, dynamic>? state, Map<String, dynamic>? config}) async {
    final h = await pumpReady(tester, dashboard, endpoints: safetyUiEndpoints(), size: tall);
    if (config != null) h.cloud.safetyConfigs[kSafetyUid] = config;
    if (state != null) {
      h.mqtt.emitStateJson(state);
      await flush(tester);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await flush(tester);
    }
    return h;
  }

  Finder inCard(String key, Finder matching) => find.descendant(of: byKeyName(key), matching: matching);

  group('kart talimatları (A.6)', () {
    testWidgets('gaz: talimat satırı, gaz vanası "yalnız yerinde açılır" notu, Aç düğmesi yok', (tester) async {
      await ready(tester, state: hazardStateJson());
      expect(find.byKey(const Key(cardKey)), findsOneWidget);
      expect(
        inCard(cardKey, find.textContaining('Ortamı havalandırın. Elektrik anahtarlarına ve prizlere dokunmayın')),
        findsOneWidget,
      );
      expect(inCard(cardKey, find.textContaining("187'yi arayın")), findsOneWidget);
      expect(byKeyName('critical_alarm_instruction_1'), findsOneWidget);
      expect(
        inCard(cardKey, find.textContaining('Gaz vanası güvenlik gereği yalnız yerinde açılır')),
        findsOneWidget,
      );
      expect(find.text('Vanayı Aç'), findsNothing);
    });

    testWidgets('gaz: ex-proof olmayan fan "çalıştırılmıyor", ex-proof fan "Havalandırma çalışıyor"', (tester) async {
      final h = await ready(tester, state: hazardStateJson(), config: hazardConfig());
      expect(inCard(cardKey, find.textContaining('Fan güvenlik gereği çalıştırılmıyor (gaz)')), findsOneWidget);

      h.cloud.safetyConfigs[kSafetyUid] = hazardConfig(exproof: true)..['rev'] = 6;
      final next = hazardStateJson(fanOn: true);
      (next['cfg'] as Map<String, dynamic>)['safety'] = <String, dynamic>{'rev': 6, 'crc': 'abcd1234'};
      h.mqtt.emitStateJson(next);
      await flush(tester);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await flush(tester);
      expect(inCard(cardKey, find.textContaining('Havalandırma çalışıyor')), findsOneWidget);
    });

    testWidgets('duman: dışarı çık + 112 talimatı ve "pano su vanasını kapatmaz"', (tester) async {
      await ready(tester, state: hazardStateJson(kind: 'smoke'));
      expect(inCard(cardKey, find.textContaining("Evde biri varsa hemen dışarı çıkın ve 112'yi arayın")), findsOneWidget);
      expect(inCard(cardKey, find.textContaining('Pano su vanasını kapatmaz')), findsOneWidget);
    });

    testWidgets('su alarmında talimat satırı yok (bugünkü kart aynı)', (tester) async {
      await ready(tester, state: safetyStateJson(zoneSt: 'latched', sensorActive: true));
      expect(find.byKey(const Key(cardKey)), findsOneWidget);
      expect(byKeyName('critical_alarm_instruction_1'), findsNothing);
    });

    testWidgets('gaz vanası arızası: türe göre metin (187)', (tester) async {
      final state = hazardStateJson(zoneSt: 'fault');
      await ready(tester, state: state);
      expect(inCard(cardKey, find.textContaining('Gaz vanası kapanmadı!')), findsOneWidget);
    });
  });

  group('gaz alarmında anahtarlama onayı (A.4)', () {
    testWidgets('lamba: vazgeç -> komut gitmez; onay -> komut gider', (tester) async {
      final h = await ready(tester, state: hazardStateJson());
      expect(h.state.hasOpenGasAlarm, isTrue);
      final before = h.cloud.sentCommands.length;
      await tester.ensureVisible(byKeyName('card_relay_1'));
      await tester.tap(byKeyName('card_relay_1'));
      await tester.pump();
      expect(find.textContaining('Gaz alarmı sürüyor.'), findsOneWidget);
      await tester.tap(byKeyName('btn_gas_switch_cancel'));
      await flush(tester);
      expect(h.cloud.sentCommands.length, before, reason: 'iptal: komut gitmez');

      await tester.tap(byKeyName('card_relay_1'));
      await tester.pump();
      await tester.tap(byKeyName('btn_gas_switch_confirm'));
      await flush(tester);
      expect(h.cloud.sentCommands.length, before + 1, reason: 'onay: komut normal hattan gider');
    });

    testWidgets('hızlı senaryo gaz alarmında onay ister', (tester) async {
      final h = await ready(tester, state: hazardStateJson());
      final before = h.cloud.sentCommands.length;
      await tester.ensureVisible(byKeyName('card_scenario_lights_off'));
      await tester.tap(byKeyName('card_scenario_lights_off'));
      await tester.pump();
      expect(byKeyName('btn_gas_switch_cancel'), findsOneWidget);
      await tester.tap(byKeyName('btn_gas_switch_cancel'));
      await flush(tester);
      expect(h.cloud.sentCommands.length, before);
    });

    testWidgets('gaz alarmı yokken (su alarmı dahil) diyalog yok, davranış bugünkü gibi', (tester) async {
      final h = await ready(tester, state: safetyStateJson(zoneSt: 'latched', sensorActive: true));
      expect(h.state.hasOpenGasAlarm, isFalse);
      final before = h.cloud.sentCommands.length;
      await tester.ensureVisible(byKeyName('card_relay_1'));
      await tester.tap(byKeyName('card_relay_1'));
      await flush(tester);
      expect(byKeyName('btn_gas_switch_cancel'), findsNothing);
      expect(h.cloud.sentCommands.length, before + 1);
    });
  });

  group('HAZARD_ACTIVE metni', () {
    test('close-all 409 HAZARD_ACTIVE -> uygulamanın Türkçe metni', () async {
      final api = MockApi();
      final service = EvCloudApiService(baseUrl: 'https://api.test/api', client: api.client, clock: FakeClock());
      addTearDown(service.dispose);
      api.on('POST', RegExp(r'close-all'), (r) => errorResponse(409, 'hazard', code: 'HAZARD_ACTIVE'));
      Object? caught;
      try {
        await service.closeAllOpenLights('home-1');
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<ApiException>());
      expect((caught! as ApiException).code, 'HAZARD_ACTIVE');
      expect(friendlyError(caught), contains('Gaz alarmı sürüyor'));
    });
  });
}
