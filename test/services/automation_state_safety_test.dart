import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/automation_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';

const String _uid = 'AHBU-S3-TEST01';

/// Kanal 7 su vanası (a1), kanal 8 siren (a2), kanal 9 gaz vanası (a3); 1-6 [testEndpoints].
List<EndpointModel> safetyEndpoints() {
  EndpointModel act(String id, int ch, String name, String type) => EndpointModel(
        id: id,
        homeId: kHomeA,
        deviceId: 'dev-internal',
        deviceUuid: _uid,
        channel: ch,
        name: name,
        room: 'Mutfak',
        endpointType: 'light',
        currentState: true, // NC selenoidin normal "röle açık" konumu: lamba sayılmamalı [Y3]
        actuatorType: type,
      );
  return <EndpointModel>[
    ...testEndpoints(),
    act('e7', 7, 'Ana Su Vanası', 'valve'),
    act('e8', 8, 'Siren', 'siren'),
    act('e9', 9, 'Gaz Vanası', 'valve'),
  ];
}

Map<String, dynamic> safetyJson({
  String zoneSt = 'normal',
  bool silenced = false,
  String aid = '9f3a11c0-3',
  String valvePos = 'open',
  bool sirenOn = false,
  bool sensorActive = false,
  bool sensorOk = true,
  Map<String, String>? rej,
  String? lastId,
  Map<int, bool> lights = const <int, bool>{},
}) {
  final base = stateJson(relays: lights, lastId: lastId);
  return <String, dynamic>{
    ...base,
    'v': 3,
    'caps': <String>['safety', 'actuator', 'event', 'cfg'],
    'last_rej': ?rej,
    'relays': <Map<String, dynamic>>[
      ...(base['relays'] as List).cast<Map<String, dynamic>>(),
      <String, dynamic>{'id': 7, 'name': 'Ana Su Vanası', 'type': 'light', 'state': true, 'act': 'valve'},
      <String, dynamic>{'id': 8, 'name': 'Siren', 'type': 'light', 'state': sirenOn, 'act': 'siren'},
      <String, dynamic>{'id': 9, 'name': 'Gaz Vanası', 'type': 'light', 'state': false, 'act': 'valve'},
    ],
    'sensors': <Map<String, dynamic>>[
      <String, dynamic>{'id': 'd3', 'src': 'di', 'kind': 'water', 'zone': 1, 'active': sensorActive, 'ok': sensorOk},
    ],
    'actuators': <Map<String, dynamic>>[
      <String, dynamic>{'id': 'a1', 'relay': 7, 'kind': 'valve', 'medium': 'water', 'zones': <int>[1], 'pos': valvePos},
      <String, dynamic>{'id': 'a2', 'relay': 8, 'kind': 'siren', 'zones': <int>[1], 'on': sirenOn},
      <String, dynamic>{'id': 'a3', 'relay': 9, 'kind': 'valve', 'medium': 'gas', 'zones': <int>[1], 'pos': 'closed'},
    ],
    'safety': <String, dynamic>{
      'policy': 'on',
      'mode': 'normal',
      'zones': <Map<String, dynamic>>[
        <String, dynamic>{'id': 1, 'st': zoneSt, 'kind': 'water', 'aid': aid, 'silenced': silenced, 'srcs': <String>['d3']},
      ],
    },
  };
}

Future<StateHarness> safetyHarness({String role = 'owner', bool brokerConnected = true}) async {
  final home = role == 'guest'
      ? HomeModel(
          id: kHomeA,
          name: 'Misafir Evi',
          role: 'guest',
          mqttTopicId: 'h_test',
          guestValidFrom: kTestNow.subtract(const Duration(hours: 1)),
          guestValidUntil: kTestNow.add(const Duration(hours: 5)),
        )
      : null;
  final h = await readyHarness(role: role, home: home, endpoints: safetyEndpoints(), brokerConnected: brokerConnected);
  return h;
}

ActuatorItem valve(AutomationState s) => s.actuatorItems.firstWhere((a) => a.id == 'a1');
ActuatorItem siren(AutomationState s) => s.actuatorItems.firstWhere((a) => a.id == 'a2');
ActuatorItem gasValve(AutomationState s) => s.actuatorItems.firstWhere((a) => a.id == 'a3');

void main() {
  late List<CommandFailure> failures;
  setUp(() => failures = <CommandFailure>[]);

  group('durum: v:3 state -> güvenlik görünümü', () {
    test('alarm, eylemci ve sensör listeleri; pano kimliği damgalı', () async {
      final h = await safetyHarness();
      addTearDown(h.dispose);
      expect(h.state.safety.supported, isFalse, reason: 'state gelmeden güvenlik bilinmiyor');
      h.mqtt.emitStateJson(safetyJson(zoneSt: 'latched', valvePos: 'closed', sensorActive: true));
      await pumpEventQueue();
      expect(h.state.safety.supported, isTrue);
      expect(h.state.safety.hasActiveAlarm, isTrue);
      expect(h.state.alarmItems.single.zone, 1);
      expect(h.state.alarmItems.single.deviceUid, _uid);
      expect(h.state.actuatorItems.map((a) => a.id), <String>['a1', 'a2', 'a3']);
      expect(h.state.sensorItems.single.isWet, isTrue);
      expect(h.state.safetyByDevice.keys, <String>[_uid]);
    });

    test('adlar uç nokta listesinden (kanal eşlemesi) doldurulur [B12]', () async {
      final h = await safetyHarness();
      addTearDown(h.dispose);
      h.mqtt.emitStateJson(safetyJson());
      await pumpEventQueue();
      expect(valve(h.state).name, 'Ana Su Vanası');
      expect(siren(h.state).name, 'Siren');
    });

    test('özdeş kalp atışı bildirim üretmez (PF-04); güvenlik değişimi bildirir', () async {
      final h = await safetyHarness();
      addTearDown(h.dispose);
      h.mqtt.emitStateJson(safetyJson());
      await pumpEventQueue();
      var notified = 0;
      h.state.addListener(() => notified++);
      h.mqtt.emitStateJson(safetyJson());
      await pumpEventQueue();
      expect(notified, 0);
      h.mqtt.emitStateJson(safetyJson(zoneSt: 'latched'));
      await pumpEventQueue();
      expect(notified, 1);
    });

    test('v:2 panoda güvenlik unsupported; lamba davranışı aynı', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.mqtt.emitStateJson(stateJson(relays: <int, bool>{1: true}));
      await pumpEventQueue();
      expect(h.state.safety, SafetyState.unsupported);
      expect(h.state.alarmItems, isEmpty);
      expect(h.state.actuatorItems, isEmpty);
      expect(h.state.relayItems.map((r) => r.id), <int>[1, 2, 5, 6]);
    });

    test('eylemci uç noktaları lamba kartına ve açık lamba sayısına girmez [Y3]', () async {
      final h = await safetyHarness();
      addTearDown(h.dispose);
      expect(h.state.relayItems.map((r) => r.id), <int>[1, 2, 5, 6], reason: 'vana/siren kanalları (7-9) yok');
      expect(h.state.openLightsCount, 0, reason: 'NC selenoidin açık rölesi lamba sayılmaz');
    });

    test('guvenlik-1: cihaz listesi değişip A panosu evden çıkınca A\'nın güvenlik kartı ve alarm öğeleri kaybolur', () async {
      final h = await safetyHarness();
      addTearDown(h.dispose);
      h.mqtt.emitStateJson(safetyJson(zoneSt: 'latched', sensorActive: true));
      await pumpEventQueue();
      expect(h.state.safetyByDevice.keys, contains(_uid));
      expect(h.state.alarmItems, isNotEmpty);

      // Pano değişimi: evde artık yalnız yeni pano var (eskisinin retained/son state'i bellekte kalmamalı).
      h.cloud.devicesByHome[kHomeA] = <DeviceInfo>[
        const DeviceInfo(deviceUuid: 'AHBU-S3-NEW001', name: 'Yeni Pano', online: true, firmware: '1.3.0'),
      ];
      var notified = 0;
      h.state.addListener(() => notified++);
      await h.state.refresh(silent: true);
      await pumpEventQueue();

      expect(h.state.safetyByDevice.containsKey(_uid), isFalse);
      expect(h.state.alarmItems, isEmpty);
      expect(h.state.actuatorItems, isEmpty);
      expect(notified, greaterThan(0));
    });

    test('ev değişiminde güvenlik durumu sıfırlanır', () async {
      final h = await safetyHarness();
      addTearDown(h.dispose);
      h.mqtt.emitStateJson(safetyJson(zoneSt: 'latched'));
      await pumpEventQueue();
      expect(h.state.alarmItems, isNotEmpty);
      await h.state.selectHome(testHome(id: kHomeB, name: 'Ev B'));
      await pumpEventQueue();
      expect(h.state.alarmItems, isEmpty);
      expect(h.state.safety.supported, isFalse);
    });
  });

  group('vana kapatma: iyimser OLABİLİR (güvenli yön)', () {
    test('kapat: anında cmd_closed görünür; uç: actuators/a1 {to: closed}; onayla kalıcı', () async {
      final h = await safetyHarness();
      addTearDown(h.dispose);
      h.state.commandFailures.listen(failures.add);
      h.mqtt.emitStateJson(safetyJson());
      await pumpEventQueue();
      final future = h.state.closeValve(valve(h.state));
      expect(valve(h.state).pos, ValvePos.cmdClosed, reason: 'iyimser');
      expect(h.state.isActuatorPending(valve(h.state)), isTrue);
      expect(await future, isTrue);
      final call = h.cloud.actuatorCalls.single;
      expect(call.deviceId, _uid);
      expect(call.actuatorId, 'a1');
      expect(call.to, 'closed');
      expect(call.commandId, isNotEmpty);
      h.mqtt.emitStateJson(safetyJson(valvePos: 'closed'));
      await pumpEventQueue();
      expect(h.state.isActuatorPending(valve(h.state)), isFalse);
      expect(valve(h.state).pos, ValvePos.closed);
      expect(failures, isEmpty);
    });

    test('misafir vanayı KAPATABİLİR (açamaz) [7.2b karar 4]', () async {
      final h = await safetyHarness(role: 'guest');
      addTearDown(h.dispose);
      h.state.commandFailures.listen(failures.add);
      h.mqtt.emitStateJson(safetyJson());
      await pumpEventQueue();
      expect(await h.state.closeValve(valve(h.state)), isTrue);
      expect(await h.state.openValve(valve(h.state)), isFalse);
      await pumpEventQueue();
      expect(failures.single.reason, CommandFailureReason.forbidden);
      expect(h.cloud.actuatorCalls.map((c) => c.to), <String>['closed']);
    });
  });

  group('vana açma: iyimser DEĞİL', () {
    test('aç: konum onaya kadar değişmez; uç: {state: open}; onayla açık görünür', () async {
      final h = await safetyHarness();
      addTearDown(h.dispose);
      h.mqtt.emitStateJson(safetyJson(valvePos: 'closed'));
      await pumpEventQueue();
      final future = h.state.openValve(valve(h.state));
      expect(valve(h.state).pos, ValvePos.closed, reason: 'açma iyimser gösterilmez');
      expect(h.state.isActuatorPending(valve(h.state)), isTrue, reason: '"uygulanıyor" göstergesi için');
      expect(await future, isTrue);
      expect(h.cloud.actuatorCalls.single.to, 'open');
      expect(valve(h.state).pos, ValvePos.closed);
      h.mqtt.emitStateJson(safetyJson(valvePos: 'open'));
      await pumpEventQueue();
      expect(h.state.isActuatorPending(valve(h.state)), isFalse);
      expect(valve(h.state).pos, ValvePos.open);
    });

    test('alarm sürerken açma: ağa çıkılmaz, gerekçeli ret (zone_latched)', () async {
      final h = await safetyHarness();
      addTearDown(h.dispose);
      h.state.commandFailures.listen(failures.add);
      h.mqtt.emitStateJson(safetyJson(zoneSt: 'latched', valvePos: 'closed'));
      await pumpEventQueue();
      expect(await h.state.openValve(valve(h.state)), isFalse);
      await pumpEventQueue();
      expect(h.cloud.actuatorCalls, isEmpty);
      expect(failures.single.code, 'zone_latched');
      expect(failures.single.message, contains('Alarm sürerken'));
    });

    test('sensör bağlantısı yokken açma reddi (kuru sayılmaz) [Y-3]', () async {
      final h = await safetyHarness();
      addTearDown(h.dispose);
      h.state.commandFailures.listen(failures.add);
      h.mqtt.emitStateJson(safetyJson(valvePos: 'closed', sensorOk: false));
      await pumpEventQueue();
      expect(await h.state.openValve(valve(h.state)), isFalse);
      await pumpEventQueue();
      expect(h.cloud.actuatorCalls, isEmpty);
      expect(failures.single.code, 'sensor_unknown');
    });

    test('gaz vanası uygulamadan açılamaz [K-4]', () async {
      final h = await safetyHarness();
      addTearDown(h.dispose);
      h.state.commandFailures.listen(failures.add);
      h.mqtt.emitStateJson(safetyJson());
      await pumpEventQueue();
      expect(await h.state.openValve(gasValve(h.state)), isFalse);
      await pumpEventQueue();
      expect(h.cloud.actuatorCalls, isEmpty);
      expect(failures.single.code, 'gas_local_only');
      expect(await h.state.closeValve(gasValve(h.state)), isTrue, reason: 'kapatma her yoldan serbest');
    });

    test('pano reddederse (last_rej) BEKLEMEDEN geri alınır; ret metni gösterilir', () async {
      final h = await safetyHarness();
      addTearDown(h.dispose);
      h.state.commandFailures.listen(failures.add);
      h.mqtt.emitStateJson(safetyJson(valvePos: 'closed'));
      await pumpEventQueue();
      await h.state.openValve(valve(h.state));
      final id = h.cloud.actuatorCalls.single.commandId;
      h.mqtt.emitStateJson(safetyJson(valvePos: 'closed', rej: <String, String>{'id': id, 'code': 'safe_mode'}));
      await pumpEventQueue();
      expect(h.state.isActuatorPending(valve(h.state)), isFalse);
      expect(failures.single.code, 'safe_mode');
      expect(failures.single.message, contains('güvenli kipte'));
      expect(h.clock.now().difference(kTestNow), lessThan(const Duration(seconds: 1)));
    });

    test('sunucu 409 ZONE_ALARM_ACTIVE: Türkçe metinle geri alınır', () async {
      final h = await safetyHarness();
      addTearDown(h.dispose);
      h.state.commandFailures.listen(failures.add);
      h.mqtt.emitStateJson(safetyJson(valvePos: 'closed'));
      await pumpEventQueue();
      h.cloud.actuatorHandler = (call) async =>
          throw const ApiException(statusCode: 409, code: 'ZONE_ALARM_ACTIVE', message: 'zone alarm active');
      expect(await h.state.openValve(valve(h.state)), isFalse);
      await pumpEventQueue();
      expect(failures.single.code, 'ZONE_ALARM_ACTIVE');
      expect(failures.single.message, contains('Alarm sürerken'));
    });
  });

  group('siren / fan: kapatma iyimser, açma değil', () {
    test('sireni sustur (off) iyimser; aç (on) iyimser değil', () async {
      final h = await safetyHarness();
      addTearDown(h.dispose);
      h.mqtt.emitStateJson(safetyJson(sirenOn: true));
      await pumpEventQueue();
      final off = h.state.setActuatorOn(siren(h.state), false);
      expect(siren(h.state).on, isFalse, reason: 'güvenli yön iyimser');
      expect(await off, isTrue);
      h.mqtt.emitStateJson(safetyJson(sirenOn: false));
      await pumpEventQueue();
      final on = h.state.setActuatorOn(siren(h.state), true);
      expect(siren(h.state).on, isFalse, reason: 'açma iyimser değil');
      expect(await on, isTrue);
      expect(h.cloud.actuatorCalls.map((c) => c.to), <String>['off', 'on']);
    });
  });

  group('alarm onayı', () {
    test('onay: alarm kaydı aid ile bulunur, ack ucu çağrılır; iyimser değil; susturulunca onaylanır', () async {
      final h = await safetyHarness();
      addTearDown(h.dispose);
      h.state.commandFailures.listen(failures.add);
      h.cloud.alarmRecords = <AlarmRecord>[
        const AlarmRecord(id: '41', zone: 1, aid: '9f3a11c0-3', kind: 'water', status: 'latched'),
      ];
      h.mqtt.emitStateJson(safetyJson(zoneSt: 'latched', sensorActive: true));
      await pumpEventQueue();
      final alarm = h.state.alarmItems.single;
      final future = h.state.ackAlarm(alarm);
      expect(h.state.alarmItems.single.silenced, isFalse, reason: 'onay iyimser değil');
      expect(await future, isTrue);
      expect(h.cloud.ackCalls.single.alarmId, '41');
      expect(h.state.isAlarmAckPending(alarm), isTrue);
      h.mqtt.emitStateJson(safetyJson(zoneSt: 'latched', sensorActive: true, silenced: true));
      await pumpEventQueue();
      expect(h.state.isAlarmAckPending(alarm), isFalse);
      expect(failures, isEmpty);
    });

    test('sunucuda kayıt yoksa (henüz açılmadı) ağa komut gitmez, anlaşılır ret', () async {
      final h = await safetyHarness();
      addTearDown(h.dispose);
      h.state.commandFailures.listen(failures.add);
      h.cloud.alarmRecords = const <AlarmRecord>[];
      h.mqtt.emitStateJson(safetyJson(zoneSt: 'latched'));
      await pumpEventQueue();
      expect(await h.state.ackAlarm(h.state.alarmItems.single), isFalse);
      await pumpEventQueue();
      expect(h.cloud.ackCalls, isEmpty);
      expect(failures.single.reason, CommandFailureReason.rejected);
    });

    test('misafir onaylayamaz', () async {
      final h = await safetyHarness(role: 'guest');
      addTearDown(h.dispose);
      h.state.commandFailures.listen(failures.add);
      h.mqtt.emitStateJson(safetyJson(zoneSt: 'latched'));
      await pumpEventQueue();
      expect(await h.state.ackAlarm(h.state.alarmItems.single), isFalse);
      await pumpEventQueue();
      expect(failures.single.reason, CommandFailureReason.forbidden);
    });
  });

  group('bölge testi', () {
    test('owner test başlatır; resident başlatamaz', () async {
      final owner = await safetyHarness();
      addTearDown(owner.dispose);
      owner.mqtt.emitStateJson(safetyJson());
      await pumpEventQueue();
      expect(await owner.state.testZone(1, deviceUid: _uid), isTrue);
      expect(owner.cloud.alarmTestCalls.single.zone, 1);

      final resident = await safetyHarness(role: 'resident');
      addTearDown(resident.dispose);
      resident.state.commandFailures.listen(failures.add);
      expect(await resident.state.testZone(1, deviceUid: _uid), isFalse);
      await pumpEventQueue();
      expect(failures.single.reason, CommandFailureReason.forbidden);
    });
  });

  group('eylemci rölesine düz röle komutu', () {
    test('setRelay / toggleRelay / triggerImpulse eylemci kanalında ağa çıkmaz (actuator_relay)', () async {
      final h = await safetyHarness();
      addTearDown(h.dispose);
      h.state.commandFailures.listen(failures.add);
      expect(await h.state.setRelay(7, false), isFalse);
      expect(await h.state.toggleRelay(8), isFalse);
      expect(await h.state.triggerImpulse(9), isFalse);
      await pumpEventQueue();
      expect(h.cloud.sentCommands, isEmpty);
      expect(failures.map((f) => f.code), <String?>['actuator_relay', 'actuator_relay', 'actuator_relay']);
    });

    test('lamba kanalları etkilenmez', () async {
      final h = await safetyHarness();
      addTearDown(h.dispose);
      expect(await h.state.setRelay(1, true), isTrue);
      expect(h.cloud.sentCommands.single['relay'], 1);
    });
  });

  group('doğrudan (LAN) kip — buluttan bağımsız (K5)', () {
    Future<StateHarness> directHarness(Map<String, dynamic> Function() status) async {
      final h = StateHarness();
      h.state.setCurrentUserForTesting(const UserModel(id: 'u', email: 'a@b.c', fullName: 'A', role: 'user'));
      h.state.setAuthStatusForTesting(AuthStatus.authenticated);
      h.state.setHomesForTesting(<HomeModel>[testHome()]);
      h.directMock.on('GET', '/api/status', (r) => jsonResponse(status()));
      await h.state.setMode(AppMode.direct);
      await h.state.setHost('192.168.1.30');
      h.direct.localKey = 'devicekey-1234';
      await h.state.refresh();
      return h;
    }

    Map<String, dynamic> lanStatus({String pos = 'open', String zoneSt = 'normal', bool silenced = false}) {
      final json = safetyJson(valvePos: pos, zoneSt: zoneSt, silenced: silenced)
        ..remove('v')
        ..remove('uid')
        ..['device'] = _uid;
      return json;
    }

    test('LAN durumundan güvenlik görünümü; vana kapatma /api/actuator', () async {
      var pos = 'open';
      final h = await directHarness(() => lanStatus(pos: pos));
      addTearDown(h.dispose);
      h.directMock.on('POST', '/api/actuator', (r) {
        pos = 'closed';
        return jsonResponse(<String, dynamic>{'ok': true, 'id': r.json?['id']});
      });
      expect(h.state.safety.supported, isTrue);
      expect(h.state.relayItems.map((r) => r.id).contains(7), isFalse);
      final future = h.state.closeValve(valve(h.state));
      expect(valve(h.state).pos, ValvePos.cmdClosed);
      expect(await future, isTrue);
      final post = h.directMock.where('POST', '/api/actuator').single;
      expect(post.json!['actuator'], 'a1');
      expect(post.json!['to'], 'closed');
      expect(post.headers['X-Device-Key'], 'devicekey-1234');
      await h.clock.elapse(const Duration(milliseconds: 400));
      expect(h.state.isActuatorPending(valve(h.state)), isFalse);
      expect(valve(h.state).pos, ValvePos.closed);
    });

    test('LAN yanıtı rej taşırsa komut anında geri alınır', () async {
      final h = await directHarness(() => lanStatus(pos: 'closed'));
      addTearDown(h.dispose);
      h.state.commandFailures.listen(failures.add);
      h.directMock.on('POST', '/api/actuator', (r) => jsonResponse(<String, dynamic>{'ok': false, 'id': r.json?['id'], 'rej': 'zone_latched'}));
      expect(await h.state.openValve(valve(h.state)), isFalse);
      await pumpEventQueue();
      expect(failures.single.code, 'zone_latched');
      expect(h.state.isActuatorPending(valve(h.state)), isFalse);
    });

    test('LAN onayı: /api/alarm/ack {zone, aid, id}', () async {
      var silenced = false;
      final h = await directHarness(() => lanStatus(zoneSt: 'latched', pos: 'closed', silenced: silenced));
      addTearDown(h.dispose);
      h.directMock.on('POST', '/api/alarm/ack', (r) {
        silenced = true;
        return jsonResponse(<String, dynamic>{'ok': true, 'id': r.json?['id']});
      });
      expect(await h.state.ackAlarm(h.state.alarmItems.single), isTrue);
      final post = h.directMock.where('POST', '/api/alarm/ack').single;
      expect(post.json!['zone'], 1);
      expect(post.json!['aid'], '9f3a11c0-3');
      expect(post.json!['id'], isA<String>());
      await h.clock.elapse(const Duration(milliseconds: 400));
      expect(h.state.alarmItems.single.silenced, isTrue);
    });
  });
}
