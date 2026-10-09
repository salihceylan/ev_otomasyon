import 'dart:convert';

import 'package:ev_otomasyon/models/automation_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tasarım §3.2'deki `state v:3` örneği (birebir).
Map<String, dynamic> specV3State() => jsonDecode('''
{
  "v": 3, "uid": "AHBU-S3-AB12CD", "fw": "1.2.0", "seq": 1240, "uptime": 3600, "ip": "192.168.1.30",
  "child_lock": false, "last_id": "c81f",
  "caps": ["safety", "actuator", "event", "cfg"],
  "boot": 57, "bn": "9f3a11c0", "time_ok": true, "epoch": 1791273600,
  "cfg": { "safety": { "rev": 12, "crc": "9a3c11f0" } },
  "last_rej": { "id": "c820", "code": "zone_latched" },
  "relays": [
    { "id": 5, "name": "Ana Su Vanası", "type": "light", "state": false, "act": "valve" },
    { "id": 6, "name": "Siren", "type": "light", "state": false, "act": "siren" }
  ],
  "shutters": [], "dis": [ { "id": 3, "state": true } ],
  "sensors": [
    { "id": "d3", "src": "di", "kind": "water", "zone": 1, "active": true, "ok": true },
    { "id": "b1", "src": "bridge", "kind": "water", "zone": 1, "active": false, "ok": false }
  ],
  "actuators": [
    { "id": "a1", "relay": 5, "kind": "valve", "medium": "water", "zones": [1], "pos": "closed", "fb": true, "fault": false },
    { "id": "a2", "relay": 6, "kind": "siren", "zones": [1], "on": true, "fault": false }
  ],
  "safety": {
    "policy": "on", "mode": "normal",
    "zones": [ { "id": 1, "st": "latched", "kind": "water", "aid": "9f3a11c0-3", "since": 1791273000, "since_up": 3000, "silenced": false, "srcs": ["d3"] } ]
  }
}
''') as Map<String, dynamic>;

/// v:2 yükü (bugünkü sahadaki panolar).
Map<String, dynamic> v2State() => <String, dynamic>{
      'v': 2,
      'uid': 'AHBU-S3-AB12CD',
      'fw': '1.1.2',
      'seq': 7,
      'last_id': 'c1',
      'relays': <Map<String, dynamic>>[
        <String, dynamic>{'id': 1, 'name': 'Salon', 'type': 'light', 'state': true},
        <String, dynamic>{'id': 2, 'name': 'Mutfak', 'type': 'light', 'state': false},
      ],
      'shutters': <Map<String, dynamic>>[],
      'dis': <Map<String, dynamic>>[],
    };

void main() {
  group('SafetyState.fromStateJson: sürüm ve yetenek', () {
    test('v:2 yükü unsupported üretir (caps yok)', () {
      final s = SafetyState.fromStateJson(v2State());
      expect(s.supported, isFalse);
      expect(s, SafetyState.unsupported);
      expect(s.alarms, isEmpty);
      expect(s.actuators, isEmpty);
      expect(s.hasActiveAlarm, isFalse);
    });

    test('caps içinde safety yoksa unsupported (yalnız event yeteneği)', () {
      final json = specV3State()..['caps'] = <String>['event'];
      expect(SafetyState.fromStateJson(json).supported, isFalse);
    });

    test('caps safety var ama safety anahtarı yok: destekli ama yapılandırılmamış', () {
      final json = specV3State()
        ..remove('safety')
        ..remove('sensors')
        ..remove('actuators');
      final s = SafetyState.fromStateJson(json);
      expect(s.supported, isTrue);
      expect(s.configured, isFalse);
      expect(s.alarms, isEmpty);
    });

    test('fw-tarama-1 (C1): kablosuz (köprü) sensör yalnız caps "bridge" iken destekli; ret kodu Türkçe metne çevrilir', () {
      final json = specV3State()..['caps'] = <String>['safety', 'actuator', 'event', 'cfg', 'intrusion'];
      expect(SafetyState.fromStateJson(json).supportsBridge, isFalse);
      json['caps'] = <String>['safety', 'actuator', 'event', 'cfg', 'bridge'];
      expect(SafetyState.fromStateJson(json).supportsBridge, isTrue);
      expect(safetyRejectMessage('sensor_bridge_unsupported'), 'Kablosuz (köprü) sensör bu panoda desteklenmiyor.');
    });

    test('bozuk tipler fırlatmaz: caps metin, safety liste, sensors nesne', () {
      final json = specV3State()
        ..['caps'] = 'safety'
        ..['safety'] = <int>[1, 2]
        ..['sensors'] = <String, dynamic>{'x': 1};
      expect(() => SafetyState.fromStateJson(json), returnsNormally);
    });
  });

  group('SafetyState.fromStateJson: §3.2 örneği birebir', () {
    late SafetyState s;
    setUp(() => s = SafetyState.fromStateJson(specV3State()));

    test('üst alanlar', () {
      expect(s.supported, isTrue);
      expect(s.configured, isTrue);
      expect(s.policy, 'on');
      expect(s.safeMode, isFalse);
      expect(s.caps, <String>['safety', 'actuator', 'event', 'cfg']);
      expect(s.lastRej, const SafetyRejection(id: 'c820', code: 'zone_latched'));
      expect(s.deviceUid, 'AHBU-S3-AB12CD');
    });

    test('sensörler', () {
      expect(s.sensors, hasLength(2));
      final d3 = s.sensors.first;
      expect(d3.id, 'd3');
      expect(d3.src, 'di');
      expect(d3.kind, 'water');
      expect(d3.zone, 1);
      expect(d3.active, isTrue);
      expect(d3.ok, isTrue);
      expect(d3.name, 'd3', reason: 'ad state\'te yok: kimlik gösterilir [B12]');
      final b1 = s.sensors[1];
      expect(b1.src, 'bridge');
      expect(b1.ok, isFalse);
    });

    test('eylemciler', () {
      expect(s.actuators, hasLength(2));
      final a1 = s.actuators.first;
      expect(a1.id, 'a1');
      expect(a1.relay, 5);
      expect(a1.kind, ActuatorKind.valve);
      expect(a1.isValve, isTrue);
      expect(a1.medium, 'water');
      expect(a1.zones, <int>[1]);
      expect(a1.pos, ValvePos.closed);
      expect(a1.feedback, isTrue);
      expect(a1.fault, isFalse);
      expect(a1.isClosedOrClosing, isTrue);
      expect(a1.deviceUid, 'AHBU-S3-AB12CD');
      final a2 = s.actuators[1];
      expect(a2.kind, ActuatorKind.siren);
      expect(a2.on, isTrue);
      expect(a2.pos, isNull);
      expect(a2.feedback, isNull);
    });

    test('bölgeler ve alarm', () {
      expect(s.zones, <int, ZoneStatus>{1: ZoneStatus.latched});
      expect(s.alarms, hasLength(1));
      final alarm = s.alarms.single;
      expect(alarm.zone, 1);
      expect(alarm.kind, 'water');
      expect(alarm.status, ZoneStatus.latched);
      expect(alarm.aid, '9f3a11c0-3');
      expect(alarm.silenced, isFalse);
      expect(alarm.sinceEpoch, 1791273000);
      expect(alarm.sinceUptime, 3000);
      expect(alarm.sources, <String>['d3']);
      expect(alarm.isActive, isTrue);
      expect(alarm.deviceUid, 'AHBU-S3-AB12CD');
      expect(s.hasActiveAlarm, isTrue);
    });

    test('normal bölge alarm değildir; test bölgesi alarm sayılmaz', () {
      final json = specV3State();
      (json['safety'] as Map<String, dynamic>)['zones'] = <Map<String, dynamic>>[
        <String, dynamic>{'id': 1, 'st': 'normal'},
        <String, dynamic>{'id': 2, 'st': 'test', 'kind': 'water'},
      ];
      final st = SafetyState.fromStateJson(json);
      expect(AlarmItem.fromZoneJson(<String, dynamic>{'id': 1, 'st': 'normal'}), isNull);
      expect(st.zones, <int, ZoneStatus>{1: ZoneStatus.normal, 2: ZoneStatus.test});
      expect(st.alarms.single.status, ZoneStatus.test);
      expect(st.hasActiveAlarm, isFalse);
    });

    test('mode safe -> safeMode', () {
      final json = specV3State();
      (json['safety'] as Map<String, dynamic>)['mode'] = 'safe';
      expect(SafetyState.fromStateJson(json).safeMode, isTrue);
    });
  });

  group('ayrıştırma dayanıklılığı', () {
    test('bilinmeyen kind unknown olur ve satır görünür kalır (fırlatmaz)', () {
      final json = specV3State();
      (json['sensors'] as List).add(<String, dynamic>{'id': 'd9', 'src': 'di', 'kind': 'lava', 'zone': 1, 'ok': true});
      (json['actuators'] as List).add(<String, dynamic>{'id': 'a3', 'relay': 7, 'kind': 'robot', 'zones': [1]});
      (json['safety'] as Map<String, dynamic>)['zones'] = <Map<String, dynamic>>[
        <String, dynamic>{'id': 1, 'st': 'exploded', 'kind': 'water'},
      ];
      final s = SafetyState.fromStateJson(json);
      expect(s.sensors.last.kind, 'unknown');
      expect(s.actuators.last.kind, ActuatorKind.unknown);
      expect(s.zones[1], ZoneStatus.unknown);
      expect(s.alarms.single.status, ZoneStatus.unknown);
    });

    test('kimliksiz / bozuk öğeler atlanır, diğerleri kalır', () {
      final json = specV3State();
      (json['sensors'] as List).addAll(<Object?>[
        <String, dynamic>{'src': 'di', 'kind': 'water'},
        'bozuk',
        null,
      ]);
      (json['actuators'] as List).addAll(<Object?>[
        <String, dynamic>{'relay': 3, 'kind': 'valve'},
        <String, dynamic>{'id': 'a9', 'relay': 0, 'kind': 'valve'},
        42,
      ]);
      final s = SafetyState.fromStateJson(json);
      expect(s.sensors.map((e) => e.id), <String>['d3', 'b1']);
      expect(s.actuators.map((e) => e.id), <String>['a1', 'a2']);
    });

    test('vana: pos yoksa unknown (konum bilinmiyor; emniyet tarafında açık kabul edilir)', () {
      final a = ActuatorItem.fromJson(<String, dynamic>{'id': 'a1', 'relay': 5, 'kind': 'valve', 'medium': 'water', 'zones': [1]});
      expect(a!.pos, ValvePos.unknown);
      expect(a.isClosedOrClosing, isFalse);
      for (final entry in <String, ValvePos>{
        'closing': ValvePos.closing,
        'open': ValvePos.open,
        'opening': ValvePos.opening,
        'cmd_closed': ValvePos.cmdClosed,
        'cmd_open': ValvePos.cmdOpen,
      }.entries) {
        final v = ActuatorItem.fromJson(<String, dynamic>{'id': 'a1', 'relay': 5, 'kind': 'valve', 'pos': entry.key});
        expect(v!.pos, entry.value);
      }
      expect(
        ActuatorItem.fromJson(<String, dynamic>{'id': 'a1', 'relay': 5, 'kind': 'valve', 'pos': 'cmd_closed'})!.isClosedOrClosing,
        isTrue,
      );
    });

    test('kesme sınırları: sensör 64, eylemci 16, bölge 4, kaynak 8', () {
      final json = specV3State();
      json['sensors'] = <Map<String, dynamic>>[
        for (var i = 1; i <= 80; i++) <String, dynamic>{'id': 'd$i', 'src': 'di', 'kind': 'water', 'zone': 1, 'ok': true},
      ];
      json['actuators'] = <Map<String, dynamic>>[
        for (var i = 1; i <= 20; i++) <String, dynamic>{'id': 'a$i', 'relay': i, 'kind': 'generic', 'zones': [1]},
      ];
      (json['safety'] as Map<String, dynamic>)['zones'] = <Map<String, dynamic>>[
        for (var i = 1; i <= 6; i++)
          <String, dynamic>{'id': i, 'st': 'latched', 'kind': 'water', 'srcs': <String>[for (var k = 0; k < 12; k++) 'd$k']},
      ];
      final s = SafetyState.fromStateJson(json);
      expect(s.sensors, hasLength(64));
      expect(s.actuators, hasLength(16));
      expect(s.alarms.length, lessThanOrEqualTo(4));
      expect(s.zones.length, lessThanOrEqualTo(4));
      expect(s.alarms.first.sources, hasLength(8));
    });

    test('last_rej: kimliksiz ya da kodsuz yok sayılır', () {
      expect(SafetyRejection.fromJson(<String, dynamic>{'code': 'busy'}), isNull);
      expect(SafetyRejection.fromJson(<String, dynamic>{'id': 'c1'}), isNull);
      expect(SafetyRejection.fromJson('x'), isNull);
      expect(SafetyRejection.fromJson(<String, dynamic>{'id': 'c1', 'code': 'busy'}), const SafetyRejection(id: 'c1', code: 'busy'));
    });

    test('ret kodlarının Türkçe metni (§5.3.3) ve bilinmeyen kod için genel metin', () {
      expect(safetyRejectMessage('zone_latched'), contains('Alarm sürerken vana açılamaz'));
      expect(safetyRejectMessage('actuator_relay'), contains('güvenlik cihazına bağlı'));
      expect(safetyRejectMessage('gas_local_only'), contains('yalnız yerinde'));
      expect(safetyRejectMessage('stale_ack'), contains('yeni bir alarm'));
      expect(safetyRejectMessage('safe_mode'), contains('güvenli kipte'));
      expect(safetyRejectMessage('???'), isNotEmpty);
      expect(isSafetyRejectCode('zone_latched'), isTrue);
      expect(isSafetyRejectCode('invalid_json'), isFalse);
    });
  });

  group('eşitlik (PF-04: özdeş kalp atışı bildirim üretmez)', () {
    test('aynı JSON iki kez: eşit ve aynı hashCode', () {
      final a = SafetyState.fromStateJson(specV3State());
      final b = SafetyState.fromStateJson(specV3State());
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a.sensors.first, b.sensors.first);
      expect(a.actuators.first, b.actuators.first);
      expect(a.alarms.first, b.alarms.first);
    });

    test('tek alan değişince eşit değil', () {
      final base = SafetyState.fromStateJson(specV3State());
      final j1 = specV3State();
      ((j1['actuators'] as List).first as Map<String, dynamic>)['pos'] = 'open';
      expect(SafetyState.fromStateJson(j1), isNot(base));
      final j2 = specV3State();
      (((j2['safety'] as Map<String, dynamic>)['zones'] as List).first as Map<String, dynamic>)['silenced'] = true;
      expect(SafetyState.fromStateJson(j2), isNot(base));
      final j3 = specV3State();
      ((j3['sensors'] as List).first as Map<String, dynamic>)['ok'] = false;
      expect(SafetyState.fromStateJson(j3), isNot(base));
      final j4 = specV3State()..['last_rej'] = <String, dynamic>{'id': 'c999', 'code': 'busy'};
      expect(SafetyState.fromStateJson(j4), isNot(base));
    });

    test('sensör adı yapılandırmadan doldurulunca kimlik eşitliği korunur, ad farkı eşitsizliktir', () {
      final s = SafetyState.fromStateJson(specV3State());
      final named = s.withNames(sensors: <String, String>{'d3': 'Mutfak Tezgah Altı'}, actuators: <String, String>{'a1': 'Ana Su Vanası'});
      expect(named.sensors.first.name, 'Mutfak Tezgah Altı');
      expect(named.actuators.first.name, 'Ana Su Vanası');
      expect(named.actuators[1].name, 'a2');
      expect(named, isNot(s));
    });
  });

  group('canOpenValve [Y-3][K-4]', () {
    SafetyState build({
      String zoneSt = 'normal',
      bool sensorActive = false,
      bool sensorOk = true,
      String mode = 'normal',
      String medium = 'water',
      List<int> valveZones = const <int>[1],
      List<Map<String, dynamic>>? extraZones,
      List<Map<String, dynamic>>? extraSensors,
    }) {
      return SafetyState.fromStateJson(<String, dynamic>{
        'v': 3,
        'uid': 'AHBU-S3-AB12CD',
        'caps': <String>['safety', 'actuator'],
        'sensors': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'd3', 'src': 'di', 'kind': 'water', 'zone': 1, 'active': sensorActive, 'ok': sensorOk},
          ...?extraSensors,
        ],
        'actuators': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'a1', 'relay': 5, 'kind': 'valve', 'medium': medium, 'zones': valveZones, 'pos': 'closed'},
          <String, dynamic>{'id': 'a2', 'relay': 6, 'kind': 'siren', 'zones': <int>[1], 'on': false},
        ],
        'safety': <String, dynamic>{
          'policy': 'on',
          'mode': mode,
          'zones': <Map<String, dynamic>>[
            <String, dynamic>{'id': 1, 'st': zoneSt, 'kind': 'water', 'aid': 'x-1'},
            ...?extraZones,
          ],
        },
      });
    }

    test('normal + kuru + ok -> açılabilir', () {
      final s = build();
      expect(s.canOpenValve(s.actuators.first), isTrue);
    });

    test('bölge kilitli -> açılamaz; gerekçe zone_latched', () {
      final s = build(zoneSt: 'latched');
      expect(s.canOpenValve(s.actuators.first), isFalse);
      expect(s.openBlockReason(s.actuators.first), 'zone_latched');
    });

    test('sensör ıslak -> açılamaz', () {
      final s = build(sensorActive: true);
      expect(s.canOpenValve(s.actuators.first), isFalse);
    });

    test('sensör ok=false (bağlantı yok) kuru sayılmaz -> açılamaz', () {
      final s = build(sensorOk: false);
      expect(s.canOpenValve(s.actuators.first), isFalse);
      expect(s.openBlockReason(s.actuators.first), 'sensor_unknown');
    });

    test('güvenli kip -> açılamaz; gerekçe safe_mode', () {
      final s = build(mode: 'safe');
      expect(s.canOpenValve(s.actuators.first), isFalse);
      expect(s.openBlockReason(s.actuators.first), 'safe_mode');
    });

    test('gaz vanası uygulamadan hiçbir zaman açılmaz', () {
      final s = build(medium: 'gas');
      expect(s.canOpenValve(s.actuators.first), isFalse);
      expect(s.openBlockReason(s.actuators.first), 'gas_local_only');
    });

    test('çok bölgeli vana: bütün bölgeler normal olmalı', () {
      final s = build(valveZones: <int>[1, 2], extraZones: <Map<String, dynamic>>[
        <String, dynamic>{'id': 2, 'st': 'fault', 'kind': 'water', 'aid': 'x-2'},
      ]);
      expect(s.canOpenValve(s.actuators.first), isFalse);
    });

    test('bölge durumu bilinmiyorsa açılamaz; firmware yazmadığı bölge normaldir (CONTRACTS §2.6)', () {
      final unknown = build(valveZones: <int>[1, 3], extraZones: <Map<String, dynamic>>[
        <String, dynamic>{'id': 3, 'st': 'tanimsiz'},
      ]);
      expect(unknown.canOpenValve(unknown.actuators.first), isFalse);
      final absent = build(valveZones: <int>[1, 3]);
      expect(absent.zoneStatus(3), ZoneStatus.normal, reason: 'safety.zones[] yalnız normal olmayan bölgeleri listeler');
      expect(absent.canOpenValve(absent.actuators.first), isTrue);
    });

    test('başka akışkanın sensörü (gaz) ıslak su vanasını engellemez', () {
      final s = build(extraSensors: <Map<String, dynamic>>[
        <String, dynamic>{'id': 'd4', 'src': 'di', 'kind': 'gas', 'zone': 1, 'active': true, 'ok': true},
      ]);
      expect(s.canOpenValve(s.actuators.first), isTrue);
    });

    test('vana olmayan eylemci "vana aç" kapsamında değildir', () {
      final s = build();
      expect(s.canOpenValve(s.actuators[1]), isFalse);
    });

    test('unsupported durumda açma yok', () {
      expect(SafetyState.unsupported.canOpenValve(build().actuators.first), isFalse);
    });
  });

  group('DeviceStatus bağlantısı', () {
    test('v:3 state: safety, lastRej, stateVersion ve röle act alanı', () {
      final st = DeviceStatus.fromJson(specV3State(), filterPhantomShutters: false);
      expect(st.stateVersion, 3);
      expect(st.safety.supported, isTrue);
      expect(st.safety.alarms.single.aid, '9f3a11c0-3');
      expect(st.lastRej, const SafetyRejection(id: 'c820', code: 'zone_latched'));
      expect(st.relayById(5)!.actuator, ActuatorKind.valve);
      expect(st.relayById(5)!.isActuator, isTrue);
      expect(st.relayById(6)!.actuator, ActuatorKind.siren);
    });

    test('controllableRelays eylemci rölelerini dışarıda bırakır (vana lamba kartına düşmez)', () {
      final json = specV3State();
      (json['relays'] as List).insert(0, <String, dynamic>{'id': 1, 'name': 'Salon', 'type': 'light', 'state': true});
      final st = DeviceStatus.fromJson(json, filterPhantomShutters: false);
      expect(st.controllableRelays.map((r) => r.id), <int>[1]);
    });

    test('v:2: safety unsupported, lastRej yok, act yok', () {
      final st = DeviceStatus.fromJson(v2State(), filterPhantomShutters: false);
      expect(st.stateVersion, 2);
      expect(st.safety, SafetyState.unsupported);
      expect(st.lastRej, isNull);
      expect(st.relays.every((r) => r.actuator == null && !r.isActuator), isTrue);
    });

    test('LAN status (v ve uid yok, device alanı): safety uid device alanından', () {
      final json = specV3State()
        ..remove('v')
        ..remove('uid')
        ..['device'] = 'AHBU-S3-AB12CD';
      final st = DeviceStatus.fromJson(json);
      expect(st.stateVersion, isNull);
      expect(st.safety.supported, isTrue);
      expect(st.safety.deviceUid, 'AHBU-S3-AB12CD');
    });

    test('sameAs güvenlik alanındaki farkı görür; özdeş yükte true', () {
      final a = DeviceStatus.fromJson(specV3State());
      final b = DeviceStatus.fromJson(specV3State());
      expect(a.sameAs(b), isTrue);
      final j = specV3State();
      (((j['safety'] as Map<String, dynamic>)['zones'] as List).first as Map<String, dynamic>)['st'] = 'normal';
      expect(a.sameAs(DeviceStatus.fromJson(j)), isFalse);
      final k = specV3State()..['last_rej'] = <String, dynamic>{'id': 'c999', 'code': 'busy'};
      expect(a.sameAs(DeviceStatus.fromJson(k)), isFalse);
    });

    test('copyWith güvenlik ve ret alanlarını korur', () {
      final a = DeviceStatus.fromJson(specV3State());
      final b = a.copyWith(childLock: true);
      expect(b.safety, a.safety);
      expect(b.lastRej, a.lastRej);
      expect(b.stateVersion, 3);
      expect(b.relayById(5)!.actuator, ActuatorKind.valve);
    });

    test('RelayItem.copyWith act alanını korur', () {
      const r = RelayItem(id: 5, name: 'V', type: 0, state: false, actuator: ActuatorKind.valve);
      expect(r.copyWith(state: true).actuator, ActuatorKind.valve);
    });
  });
}
