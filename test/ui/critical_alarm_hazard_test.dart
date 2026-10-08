import 'package:ev_otomasyon/models/automation_models.dart';
import 'package:ev_otomasyon/services/alarm_watch/alarm_notice.dart';
import 'package:ev_otomasyon/ui/dashboard/apartment_dashboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/safety_fixtures.dart';
import '../support/support.dart';
import 'e1_helpers.dart';

/// guvenlik-2 / guvenlik-11: kritik alarm kartı ıslaklık / kaynak hesabına yalnız aynı panonun aynı bölgedeki su, gaz ve
/// duman sensörlerini katar (kapı/pencere/hareket ve kumanda rolleri hariç); aynı bölgede birden çok tehlike tek türe
/// indirgenmez (vana, talimat ve arıza metinleri tehlike kümesinden).
void main() {
  const dashboard = Scaffold(body: ApartmentDashboard());
  const tall = Size(800, 3200);
  const cardKey = 'card_critical_alarm_${kSafetyUid}_1';

  Future<void> flush(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  Map<String, dynamic> state({
    required List<Map<String, dynamic>> sensors,
    String zoneSt = 'latched',
    String kind = 'water',
    List<String> srcs = const <String>['d3'],
    bool silenced = false,
    String uid = kSafetyUid,
    Set<String> faultyValves = const <String>{},
  }) {
    final base = safetyStateJson(zoneSt: zoneSt, silenced: silenced, valvePos: 'closed');
    base['uid'] = uid;
    base['sensors'] = sensors;
    base['actuators'] = <Map<String, dynamic>>[
      for (final a in (base['actuators'] as List).cast<Map<String, dynamic>>())
        <String, dynamic>{...a, if (faultyValves.contains(a['id'])) 'fault': true},
    ];
    final safety = base['safety'] as Map<String, dynamic>;
    final zones = (safety['zones'] as List).cast<Map<String, dynamic>>();
    safety['zones'] = <Map<String, dynamic>>[
      for (final z in zones) <String, dynamic>{...z, 'kind': kind, 'srcs': srcs},
    ];
    return base;
  }

  Map<String, dynamic> sensor(String id, String kind, {bool active = false, bool ok = true, int zone = 1}) =>
      <String, dynamic>{'id': id, 'src': 'di', 'kind': kind, 'zone': zone, 'active': active, 'ok': ok};

  Future<StateHarness> ready(WidgetTester tester, List<Map<String, dynamic>> states) async {
    final h = await pumpReady(tester, dashboard, endpoints: safetyUiEndpoints(), size: tall);
    for (final s in states) {
      h.mqtt.emitStateJson(s);
    }
    await flush(tester);
    return h;
  }

  Finder inCard(Finder matching) => find.descendant(of: find.byKey(const Key(cardKey)), matching: matching);

  group('guvenlik-2: ıslaklık hesabı', () {
    testWidgets('kapı açık / hareket aktifken susturulmuş su alarmında "Alarmı Onayla" görünür', (tester) async {
      await ready(tester, <Map<String, dynamic>>[
        state(silenced: true, sensors: <Map<String, dynamic>>[
          sensor('d3', 'water'),
          sensor('d5', 'door', active: true),
          sensor('d6', 'motion', active: true),
          sensor('d7', 'alarm_ack', active: true),
        ]),
      ]);
      expect(inCard(find.text('Alarmı Onayla')), findsOneWidget);
      expect(find.byKey(const Key('btn_alarm_ack_1')), findsOneWidget);
    });

    testWidgets('başka panonun aynı numaralı bölgesindeki ıslak sensör kararı etkilemez', (tester) async {
      await ready(tester, <Map<String, dynamic>>[
        state(uid: 'AHBU-S3-OTHER2', zoneSt: 'normal', sensors: <Map<String, dynamic>>[sensor('d3', 'water', active: true)]),
        state(silenced: true, sensors: <Map<String, dynamic>>[sensor('d3', 'water')]),
      ]);
      expect(inCard(find.text('Alarmı Onayla')), findsOneWidget);
    });

    testWidgets('yanıt vermeyen (ok=false) su sensöründe uyarı satırı; düğme gizlenmez', (tester) async {
      await ready(tester, <Map<String, dynamic>>[
        state(sensors: <Map<String, dynamic>>[sensor('d3', 'water', ok: false)]),
      ]);
      expect(inCard(find.text('Sensör yanıt vermiyor; alarm kalkamaz')), findsOneWidget);
      expect(find.byKey(const Key('btn_alarm_ack_1')), findsOneWidget);
    });
  });

  group('guvenlik-11: tehlike kümesi', () {
    testWidgets('duman + su: su vanası görünür; "Pano su vanasını kapatmaz" yazılmaz', (tester) async {
      await ready(tester, <Map<String, dynamic>>[
        state(kind: 'smoke', srcs: const <String>['d4', 'd3'], sensors: <Map<String, dynamic>>[
          sensor('d4', 'smoke', active: true),
          sensor('d3', 'water', active: true),
        ]),
      ]);
      expect(inCard(find.textContaining('Ana Su Vanası:')), findsOneWidget);
      expect(inCard(find.textContaining('Pano su vanasını kapatmaz')), findsNothing);
      expect(inCard(find.textContaining("112'yi arayın")), findsOneWidget);
    });

    testWidgets('yalnız duman: vana gösterilmez', (tester) async {
      await ready(tester, <Map<String, dynamic>>[
        state(kind: 'smoke', srcs: const <String>['d4'], sensors: <Map<String, dynamic>>[sensor('d4', 'smoke', active: true)]),
      ]);
      expect(inCard(find.textContaining('Ana Su Vanası:')), findsNothing);
      expect(inCard(find.textContaining('Gaz Vanası:')), findsNothing);
      expect(inCard(find.textContaining('Pano su vanasını kapatmaz')), findsOneWidget);
    });

    testWidgets('gaz + su: iki vana da görünür', (tester) async {
      await ready(tester, <Map<String, dynamic>>[
        state(kind: 'gas', srcs: const <String>['g1', 'd3'], sensors: <Map<String, dynamic>>[
          sensor('g1', 'gas', active: true),
          sensor('d3', 'water', active: true),
        ]),
      ]);
      expect(inCard(find.textContaining('Ana Su Vanası:')), findsOneWidget);
      expect(inCard(find.textContaining('Gaz Vanası:')), findsOneWidget);
    });

    testWidgets('arıza satırı arızalı vananın akışkanına göre (gaz alarmında su vanası arızası)', (tester) async {
      await ready(tester, <Map<String, dynamic>>[
        state(
          zoneSt: 'fault',
          kind: 'gas',
          srcs: const <String>['g1', 'd3'],
          faultyValves: const <String>{'a1'},
          sensors: <Map<String, dynamic>>[sensor('g1', 'gas', active: true), sensor('d3', 'water', active: true)],
        ),
      ]);
      expect(inCard(find.text('Vana kapanmadı! Ana vanayı elle kapatın.')), findsOneWidget);
      expect(inCard(find.textContaining('Gaz vanası kapanmadı')), findsNothing);
    });
  });

  test('guvenlik-11: bildirim başlığı ve gövdesi tehlike kümesinden (duman + su)', () {
    SafetyState s(String st) => SafetyState.fromStateJson(<String, dynamic>{
          'v': 3,
          'uid': kSafetyUid,
          'caps': <String>['safety', 'actuator', 'event'],
          'sensors': <Map<String, dynamic>>[
            sensor('d4', 'smoke', active: st != 'normal'),
            sensor('d3', 'water', active: st != 'normal'),
          ],
          'safety': <String, dynamic>{
            'policy': 'on',
            'zones': <Map<String, dynamic>>[
              if (st != 'normal')
                <String, dynamic>{'id': 1, 'st': st, 'kind': 'smoke', 'aid': 'x-1', 'srcs': <String>['d4', 'd3']},
            ],
          },
        });
    final n = planAlarmNotices(homeId: kHomeA, homeName: 'Evim', before: s('normal'), after: s('latched')).show.single;
    expect(n.title, startsWith('Duman algılandı + Su baskını:'));
    expect(n.body, contains("112'yi arayın"));
    expect(n.body, isNot(contains('Pano su vanasını kapatmaz')));
  });
}
