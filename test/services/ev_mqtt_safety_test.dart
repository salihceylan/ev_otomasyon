import 'dart:convert';
import 'dart:math';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/automation_models.dart';
import 'package:ev_otomasyon/services/ev_mqtt_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';

const String _uid = 'AHBU-S3-ABC123';

String v3State({
  String uid = _uid,
  String zoneSt = 'normal',
  String aid = '9f3a11c0-1',
  bool silenced = false,
  bool sensorOk = true,
  bool sensorActive = false,
  String mode = 'normal',
  Map<String, String>? rej,
  bool caps = true,
}) =>
    jsonEncode(<String, dynamic>{
      'v': 3,
      'uid': uid,
      if (caps) 'caps': <String>['safety', 'actuator', 'event'],
      'relays': <Map<String, dynamic>>[
        <String, dynamic>{'id': 1, 'name': 'Salon', 'type': 'light', 'state': true},
        <String, dynamic>{'id': 5, 'name': 'Vana', 'type': 'light', 'state': false, 'act': 'valve'},
      ],
      'shutters': <Map<String, dynamic>>[],
      'last_rej': ?rej,
      'sensors': <Map<String, dynamic>>[
        <String, dynamic>{'id': 'd3', 'src': 'di', 'kind': 'water', 'zone': 1, 'active': sensorActive, 'ok': sensorOk},
      ],
      'actuators': <Map<String, dynamic>>[
        <String, dynamic>{'id': 'a1', 'relay': 5, 'kind': 'valve', 'medium': 'water', 'zones': <int>[1], 'pos': 'closed'},
      ],
      'safety': <String, dynamic>{
        'policy': 'on',
        'mode': mode,
        'zones': <Map<String, dynamic>>[
          <String, dynamic>{'id': 1, 'st': zoneSt, 'kind': 'water', 'aid': aid, 'silenced': silenced, 'srcs': <String>['d3']},
        ],
      },
    });

void main() {
  late FakeClock clock;
  late FakeMqttTransport transport;
  late EvMqttService service;
  late List<DeviceStateMessage> states;
  late List<SafetyEvent> events;

  setUp(() async {
    clock = FakeClock();
    service = EvMqttService(
      clock: clock,
      random: Random(1),
      useTls: true,
      transportFactory: () => transport = FakeMqttTransport(),
    );
    states = <DeviceStateMessage>[];
    events = <SafetyEvent>[];
    service.stateMessages.listen(states.add);
    service.safetyEvents.listen(events.add);
    await service.start(
      credentialsProvider: () async => MqttCredentials(
        host: 'broker.test',
        port: 8884,
        username: 'u',
        password: 'gecici',
        expiresAt: clock.now().add(const Duration(hours: 12)),
        topicId: 'h_abc',
        clientId: 'cid',
      ),
    );
    await pumpEventQueue();
  });
  tearDown(() => service.dispose());

  void deliver(String payload, {bool retained = false}) =>
      service.ingestBatch(<MqttInboundMessage>[MqttInboundMessage(topic: 'ev/h_abc/state', payload: payload, retained: retained)]);

  test('uygulama event konusuna ABONE OLMAZ (ACL değişmez; alarm state + push ile gelir) §3.4', () {
    expect(transport.subscriptions, <String>['ev/h_abc/state', 'ev/h_abc/status']);
  });

  test('v:3 state ayrıştırılır: güvenlik alanı ve röle act', () async {
    deliver(v3State(zoneSt: 'latched'));
    await pumpEventQueue();
    final st = states.single.status;
    expect(st.stateVersion, 3);
    expect(st.safety.supported, isTrue);
    expect(st.safety.hasActiveAlarm, isTrue);
    expect(st.relayById(5)!.actuator, ActuatorKind.valve);
    expect(st.controllableRelays.map((r) => r.id), <int>[1]);
  });

  test('v:2 state: güvenlik olayı üretmez', () async {
    deliver('{"v":2,"uid":"$_uid","relays":[{"id":1,"name":"R","type":"light","state":true}],"shutters":[]}');
    deliver('{"v":2,"uid":"$_uid","relays":[{"id":1,"name":"R","type":"light","state":false}],"shutters":[]}');
    await pumpEventQueue();
    expect(states, hasLength(2));
    expect(events, isEmpty);
  });

  test('alarm yaşam döngüsü: raised -> silenced -> fault -> fault cleared -> cleared', () async {
    deliver(v3State());
    deliver(v3State(zoneSt: 'latched', sensorActive: true));
    deliver(v3State(zoneSt: 'latched', sensorActive: true, silenced: true));
    deliver(v3State(zoneSt: 'fault', sensorActive: true, silenced: true));
    deliver(v3State(zoneSt: 'latched', silenced: true));
    deliver(v3State());
    await pumpEventQueue();
    expect(events.map((e) => e.type), <SafetyEventType>[
      SafetyEventType.alarmRaised,
      SafetyEventType.alarmSilenced,
      SafetyEventType.valveFault,
      SafetyEventType.valveFaultCleared,
      SafetyEventType.alarmCleared,
    ]);
    final raised = events.first;
    expect(raised.deviceUid, _uid);
    expect(raised.zone, 1);
    expect(raised.aid, '9f3a11c0-1');
    expect(raised.kind, 'water');
    expect(raised.initial, isFalse);
  });

  test('özdeş kalp atışı olay üretmez', () async {
    deliver(v3State(zoneSt: 'latched'));
    deliver(v3State(zoneSt: 'latched'));
    deliver(v3State(zoneSt: 'latched'));
    await pumpEventQueue();
    expect(events, hasLength(1));
    expect(events.single.initial, isTrue, reason: 'ilk görülen (retained/bağlanış) durum');
  });

  test('aynı bölgede yeni aid = yeni alarm', () async {
    deliver(v3State(zoneSt: 'latched', aid: 'aa-1'));
    deliver(v3State(zoneSt: 'latched', aid: 'aa-2'));
    await pumpEventQueue();
    expect(events.map((e) => e.aid), <String?>['aa-1', 'aa-2']);
    expect(events.every((e) => e.type == SafetyEventType.alarmRaised), isTrue);
  });

  test('sensör arızası ve güvenli kip olayları', () async {
    deliver(v3State());
    deliver(v3State(sensorOk: false));
    deliver(v3State());
    deliver(v3State(mode: 'safe'));
    await pumpEventQueue();
    expect(events.map((e) => e.type), <SafetyEventType>[
      SafetyEventType.sensorFault,
      SafetyEventType.sensorFaultCleared,
      SafetyEventType.safeModeEntered,
    ]);
    expect(events.first.sensorId, 'd3');
  });

  test('yeni last_rej -> commandRejected; ilk görülen eski ret olay değildir', () async {
    deliver(v3State(rej: <String, String>{'id': 'eski', 'code': 'busy'}));
    deliver(v3State(rej: <String, String>{'id': 'c9', 'code': 'zone_latched'}));
    await pumpEventQueue();
    expect(events.single.type, SafetyEventType.commandRejected);
    expect(events.single.rejection, const SafetyRejection(id: 'c9', code: 'zone_latched'));
  });

  test('safety kaybolursa (firmware geri alındı / yapılandırma silindi) "cleared" UYDURULMAZ [O11]', () async {
    deliver(v3State(zoneSt: 'latched'));
    deliver(v3State(caps: false));
    await pumpEventQueue();
    expect(events.map((e) => e.type), <SafetyEventType>[SafetyEventType.alarmRaised]);
  });

  test('panolar ayrı izlenir; durdurunca geçmiş sıfırlanır', () async {
    deliver(v3State(uid: 'AHBU-S3-AAAA01', zoneSt: 'latched'));
    deliver(v3State(uid: 'AHBU-S3-BBBB02'));
    await pumpEventQueue();
    expect(events, hasLength(1));
    expect(events.single.deviceUid, 'AHBU-S3-AAAA01');
    await service.stop();
    await service.start(
      credentialsProvider: () async => MqttCredentials(
        host: 'broker.test',
        port: 8884,
        username: 'u',
        password: 'gecici',
        expiresAt: clock.now().add(const Duration(hours: 12)),
        topicId: 'h_abc',
        clientId: 'cid',
      ),
    );
    await pumpEventQueue();
    deliver(v3State(uid: 'AHBU-S3-AAAA01', zoneSt: 'latched'), retained: true);
    await pumpEventQueue();
    expect(events, hasLength(2));
    expect(events.last.initial, isTrue);
    expect(events.last.retained, isTrue);
  });
}
