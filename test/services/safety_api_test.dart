import 'package:ev_otomasyon/models/automation_models.dart';
import 'package:ev_otomasyon/services/automation_api_service.dart';
import 'package:ev_otomasyon/services/ev_cloud_api_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';

const String _home = '11111111-1111-4111-8111-111111111111';

void main() {
  group('bulut uçları (tasarım §5.2.4)', () {
    late MockApi api;
    late EvCloudApiService service;
    setUp(() {
      api = MockApi();
      service = EvCloudApiService(baseUrl: 'https://api.test/api', client: api.client, clock: FakeClock())..setAuthToken('t');
    });
    tearDown(() => service.dispose());

    test('eylemci: POST /homes/:h/devices/:d/actuators/:a {to, id} (CONTRACTS §1.5d)', () async {
      api.on('POST', RegExp(r'/api/v1/homes/[^/]+/devices/[^/]+/actuators/[^/]+$'),
          (r) => okResponse(<String, dynamic>{'delivered': true, 'command_id': r.json?['id']}));
      final result = await service.actuatorCommand(
        homeId: _home,
        deviceId: 'AHBU-S3-TEST01',
        actuatorId: 'a1',
        to: 'closed',
        commandId: 'c1',
      );
      final req = api.requests.single;
      expect(req.path, '/api/v1/homes/$_home/devices/AHBU-S3-TEST01/actuators/a1');
      expect(req.json, <String, dynamic>{'to': 'closed', 'id': 'c1'});
      expect(result.delivered, isTrue);
      expect(result.commandId, 'c1');
    });

    test('güvenlik yanıtında delivered yoksa iletildi SAYILMAZ (fail-closed)', () async {
      api.on('POST', RegExp(r'/actuators/'), (r) => okResponse(<String, dynamic>{}));
      final result = await service.actuatorCommand(homeId: _home, deviceId: 'd', actuatorId: 'a1', to: 'open', commandId: 'c2');
      expect(result.delivered, isFalse);
    });

    test('onay: POST /homes/:h/alarms/:id/ack {id}; test: POST …/alarm-test {zone, id}', () async {
      api
        ..on('POST', RegExp(r'/alarms/[^/]+/ack$'), (r) => okResponse(<String, dynamic>{'delivered': true}))
        ..on('POST', RegExp(r'/alarm-test$'), (r) => okResponse(<String, dynamic>{'delivered': true}));
      await service.ackAlarm(homeId: _home, alarmId: '41', commandId: 'c3');
      await service.alarmTest(homeId: _home, deviceId: 'AHBU-S3-TEST01', zone: 2, commandId: 'c4');
      expect(api.requests[0].path, '/api/v1/homes/$_home/alarms/41/ack');
      expect(api.requests[0].json, <String, dynamic>{'id': 'c3'});
      expect(api.requests[1].path, '/api/v1/homes/$_home/devices/AHBU-S3-TEST01/alarm-test');
      expect(api.requests[1].json, <String, dynamic>{'zone': 2, 'id': 'c4'});
    });

    test('alarm listesi: GET /homes/:h/alarms?state=open; bozuk kayıt atlanır', () async {
      api.on('GET', '/api/v1/homes/$_home/alarms', (r) => okResponse(<String, dynamic>{
            'alarms': <Object?>[
              <String, dynamic>{'id': 41, 'zone': 1, 'aid': '9f3a11c0-3', 'kind': 'water', 'status': 'latched', 'raised_at': '2026-10-06T10:00:00Z'},
              <String, dynamic>{'id': 42, 'zone': 1},
              'bozuk',
            ],
          }));
      final list = await service.alarms(_home);
      expect(api.requests.single.url.queryParameters, <String, String>{'state': 'open'});
      expect(list.single.id, '41');
      expect(list.single.aid, '9f3a11c0-3');
      expect(list.single.isOpen, isTrue);
      expect(list.single.raisedAt, DateTime.utc(2026, 10, 6, 10));
    });
  });

  group('LAN uçları (tasarım §3.5)', () {
    late MockApi mock;
    late AutomationApiService api;
    setUp(() {
      mock = MockApi();
      api = AutomationApiService(baseUrl: 'http://192.168.1.30', localKey: 'devicekey-1234', client: mock.client, clock: FakeClock());
    });

    test('POST /api/actuator {actuator, to, id} (firmware gövdesi)', () async {
      mock.on('POST', '/api/actuator', (r) => jsonResponse(<String, dynamic>{'ok': true, 'id': 'c1'}));
      await api.postActuator('a1', 'closed', id: 'c1');
      final req = mock.requests.single;
      expect(req.json, <String, dynamic>{'actuator': 'a1', 'to': 'closed', 'id': 'c1'});
      expect(req.headers['X-Device-Key'], 'devicekey-1234');
    });

    test('yanıt rej taşırsa 409 + kod + Türkçe metin', () async {
      mock.on('POST', '/api/actuator', (r) => jsonResponse(<String, dynamic>{'ok': false, 'id': 'c1', 'rej': 'gas_local_only'}));
      await expectLater(
        api.postActuator('a3', 'open', id: 'c1'),
        throwsA(isA<LocalApiException>()
            .having((e) => e.statusCode, 'statusCode', 409)
            .having((e) => e.code, 'code', 'gas_local_only')
            .having((e) => e.message, 'message', contains('yalnız yerinde'))),
      );
    });

    test('HTTP 409 {"error":"zone_latched"} Türkçe metne çevrilir', () async {
      mock.on('POST', '/api/actuator', (r) => jsonResponse(<String, dynamic>{'error': 'zone_latched'}, status: 409));
      await expectLater(
        api.postActuator('a1', 'open'),
        throwsA(isA<LocalApiException>().having((e) => e.message, 'message', contains('Alarm sürerken'))),
      );
    });

    test('geçersiz hedef ağa çıkmaz', () async {
      await expectLater(api.postActuator('a1', 'yarim'), throwsA(isA<LocalApiException>()));
      await expectLater(api.ackAlarm(5), throwsA(isA<LocalApiException>()));
      expect(mock.requests, isEmpty);
    });

    test('onay {zone, aid, id}, test {zone, id}', () async {
      mock
        ..on('POST', '/api/alarm/ack', (r) => jsonResponse(<String, dynamic>{'ok': true}))
        ..on('POST', '/api/alarm/test', (r) => jsonResponse(<String, dynamic>{'ok': true}));
      await api.ackAlarm(1, aid: '9f3a11c0-3', id: 'c5');
      await api.testAlarm(2, id: 'c6');
      expect(mock.requests[0].json, <String, dynamic>{'zone': 1, 'aid': '9f3a11c0-3', 'id': 'c5'});
      expect(mock.requests[1].json, <String, dynamic>{'zone': 2, 'id': 'c6'});
    });

    test('internetsiz olay geçmişi: GET /api/events?after=', () async {
      mock.on('GET', '/api/events', (r) => jsonResponse(<String, dynamic>{
            'events': <Object?>[
              <String, dynamic>{'eid': '9f3a11c0-3', 'type': 'alarm_raised', 'zone': 1, 'kind': 'water', 'srcs': <String>['d3'], 'at_up': 3000},
              <String, dynamic>{'type': 'eksik_eid'},
            ],
          }));
      final events = await api.fetchEvents(after: '9f3a11c0-2');
      expect(mock.requests.single.url.queryParameters, <String, String>{'after': '9f3a11c0-2'});
      expect(events.single, const DeviceEventRecord(eid: '9f3a11c0-3', type: 'alarm_raised', zone: 1, kind: 'water', sources: <String>['d3'], atUptime: 3000));
    });
  });
}
