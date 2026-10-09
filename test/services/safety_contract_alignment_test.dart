import 'package:ev_otomasyon/models/automation_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_api_service.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/services/command_pipeline.dart';
import 'package:ev_otomasyon/services/ev_cloud_api_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/safety_fixtures.dart';
import '../support/support.dart';

/// Sözleşme hizalaması (CONTRACTS §1.5d, §2.6): firmware v1.2.0 / sunucu WP-S4 gerçek biçimleriyle uygulama.
/// Her test bir uyumsuzluğun düzeltmesini kilitler.
const String _home = '11111111-1111-4111-8111-111111111111';

/// Firmware'in GERÇEK `state v:3` biçimi: `safety.zones[]` yalnız NORMAL OLMAYAN bölgeleri yazar (yokluğu = normal),
/// `cfg.safety` yapılandırma sürümünü taşır, sensör listesinde yerel kumanda rolleri de bulunur.
Map<String, dynamic> firmwareState({List<Map<String, dynamic>> zones = const <Map<String, dynamic>>[], int rev = 5}) {
  final base = safetyStateJson();
  return <String, dynamic>{
    ...base,
    'cfg': <String, dynamic>{
      'safety': <String, dynamic>{'rev': rev, 'crc': '9A3C11F0'},
    },
    'sensors': <Map<String, dynamic>>[
      ...(base['sensors'] as List).cast<Map<String, dynamic>>(),
      <String, dynamic>{'id': 'd8', 'src': 'di', 'kind': 'alarm_ack', 'zone': 1, 'active': true, 'ok': true},
    ],
    'safety': <String, dynamic>{'policy': 'on', 'mode': 'normal', 'zones': zones},
  };
}

void main() {
  group('state v:3 (firmware SafetyView)', () {
    test('bildirilmeyen bölge normaldir: vana açma engellenmez; kumanda rolü sensör engeli sayılmaz', () {
      final s = SafetyState.fromStateJson(firmwareState());
      expect(s.zones, isEmpty);
      expect(s.zoneStatus(1), ZoneStatus.normal);
      final valve = s.actuatorById('a1')!;
      expect(s.openBlockReason(valve), isNull, reason: 'alarm yok, sensör kuru; basılı onay düğmesi ıslaklık değildir');
      expect(s.sensors.last.kind, 'alarm_ack');
      expect(s.sensors.last.isControl, isTrue);
      expect(s.cfgRev, 5);
      expect(s.cfgCrc, '9a3c11f0');
      final latched = SafetyState.fromStateJson(firmwareState(zones: <Map<String, dynamic>>[
        <String, dynamic>{'id': 1, 'st': 'latched', 'kind': 'water', 'aid': '9f3a11c0-3', 'since_up': 3, 'silenced': false, 'srcs': <String>['d3']},
      ]));
      expect(latched.openBlockReason(latched.actuatorById('a1')!), 'zone_latched');
      expect(SafetyState.unsupported.zoneStatus(1), ZoneStatus.unknown);
    });

    test('alarm onayı onayı: kilit kalkınca bölge listeden düşer -> onaylandı sayılır', () {
      final confirm = CommandConfirm.alarmSilencedOrCleared(1, uid: kSafetyUid);
      final cleared = DeviceStatus.fromJson(firmwareState());
      expect(confirm(cleared), isTrue);
      final stillLatched = DeviceStatus.fromJson(firmwareState(zones: <Map<String, dynamic>>[
        <String, dynamic>{'id': 1, 'st': 'latched', 'aid': '9f3a11c0-3', 'since_up': 3, 'silenced': false, 'srcs': <String>[]},
      ]));
      expect(confirm(stillLatched), isFalse);
    });
  });

  group('olaylar ve yapılandırma kopyası', () {
    test('LAN olayı aid taşır (alarm_cleared); alarm_raised için alarm kimliği eid', () {
      final cleared = DeviceEventRecord.fromJson(const <String, dynamic>{
        'eid': '0badf00d-4', 'type': 'alarm_cleared', 'zone': 1, 'kind': 'water', 'aid': '9F3A11C0-3', 'at_up': 9,
      });
      expect(cleared.aid, '9f3a11c0-3');
      expect(cleared.alarmId, '9f3a11c0-3');
      final raised = DeviceEventRecord.fromJson(const <String, dynamic>{'eid': '9f3a11c0-3', 'type': 'alarm_raised', 'zone': 1});
      expect(raised.alarmId, '9f3a11c0-3');
      final test = DeviceEventRecord.fromJson(const <String, dynamic>{'eid': '0badf00d-5', 'type': 'test_result', 'zone': 1, 'ok': true});
      expect(test.fbMs, isNull, reason: 'geri bildirimsiz bölgede firmware fb_ms yazmaz');
    });

    test('ad kopyası (cfg_dump / GET /api/safety/config biçimi) çözülür; kontrol karakterleri atılır', () {
      final names = SafetyConfigNames.fromJson(const <String, dynamic>{
        'rev': 5,
        'crc': '9a3c11f0',
        'zones': <Object?>[
          <String, dynamic>{'id': 1, 'name': 'Mutfak'},
          <String, dynamic>{'id': 2, 'name': ''},
        ],
        'sensors': <Object?>[
          <String, dynamic>{'id': 'd3', 'kind': 'water', 'name': 'Evye\talti'},
          <String, dynamic>{'id': 'x9', 'name': 'Bozuk'},
        ],
        'actuators': <Object?>[
          <String, dynamic>{'id': 'a1', 'relay': 7, 'name': 'Ana vana'},
        ],
      });
      expect(names.sensors, <String, String>{'d3': 'Evyealti'});
      expect(names.actuators, <String, String>{'a1': 'Ana vana'});
      expect(names.zones, <int, String>{1: 'Mutfak'});
      expect(names.matches(SafetyState.fromStateJson(firmwareState())), isTrue);
      expect(names.matches(SafetyState.fromStateJson(firmwareState(rev: 6))), isFalse);
    });
  });

  group('sunucu ret kodları', () {
    test('409 DEVICE_REJECTED reason -> firmware ret metni ve kodu; ack_queued -> kuyruk metni', () {
      final rejected = CommandFailure.fromError(
        'k',
        const ApiException(statusCode: 409, code: 'DEVICE_REJECTED', message: 'x', details: <String, dynamic>{'reason': 'stale_ack'}),
      );
      expect(rejected.code, 'stale_ack');
      expect(rejected.message, contains('yeni bir alarm'));
      final queued = CommandFailure.fromError(
        'k',
        const ApiException(statusCode: 409, code: 'DEVICE_OFFLINE', message: 'x', details: <String, dynamic>{'ack_queued': true}),
      );
      expect(queued.reason, CommandFailureReason.offline);
      expect(queued.message, contains('pano bağlanınca'));
    });
  });

  group('bulut uçları', () {
    late MockApi api;
    late EvCloudApiService service;
    setUp(() {
      api = MockApi();
      service = EvCloudApiService(baseUrl: 'https://api.test/api', client: api.client, clock: FakeClock())..setAuthToken('t');
    });
    tearDown(() => service.dispose());

    test('alarm listesi data.items okunur; before alarm kimliğidir', () async {
      api.on('GET', '/api/v1/homes/$_home/alarms', (r) => okResponse(<String, dynamic>{
            'items': <Object?>[
              <String, dynamic>{'id': 41, 'device_uuid': 'ahbu-s3-test01', 'zone': 1, 'aid': '9f3a11c0-3', 'kind': 'water', 'status': 'cleared'},
            ],
            'next_before': 41,
          }));
      final list = await service.alarms(_home, openOnly: false, before: '50');
      expect(api.requests.single.url.queryParameters, <String, String>{'state': 'all', 'before': '50'});
      expect(list.single.id, '41');
      expect(list.single.deviceUuid, 'AHBU-S3-TEST01');
      expect(list.single.isOpen, isFalse);
    });

    test('yapılandırma kopyası: GET …/devices/:uid/safety-config', () async {
      api.on('GET', RegExp(r'/safety-config$'), (r) => okResponse(<String, dynamic>{
            'device_uuid': 'AHBU-S3-TEST01',
            'rev': 5,
            'crc': '9a3c11f0',
            'sensors': <Object?>[
              <String, dynamic>{'id': 'd3', 'name': 'Evye'},
            ],
            'actuators': <Object?>[],
          }));
      final cfg = await service.safetyConfig(_home, 'AHBU-S3-TEST01');
      expect(api.requests.single.path, '/api/v1/homes/$_home/devices/AHBU-S3-TEST01/safety-config');
      expect(SafetyConfigNames.fromJson(cfg).sensors['d3'], 'Evye');
    });
  });

  group('LAN uçları', () {
    late MockApi mock;
    late AutomationApiService api;
    setUp(() {
      mock = MockApi();
      api = AutomationApiService(baseUrl: 'http://192.168.1.30', localKey: 'devicekey-1234', client: mock.client, clock: FakeClock());
    });

    test('olay halkası sayfalanır: more=true iken son eid ile devam; yinelenen eid atlanır', () async {
      mock.on('GET', '/api/events', (r) {
        final after = r.url.queryParameters['after'];
        if (after == null) {
          return jsonResponse(<String, dynamic>{
            'bn': '0badf00d',
            'events': <Object?>[
              <String, dynamic>{'eid': '0badf00d-1', 'type': 'alarm_raised', 'zone': 1},
              <String, dynamic>{'eid': '0badf00d-2', 'type': 'alarm_cleared', 'zone': 1, 'aid': '0badf00d-1'},
            ],
            'more': true,
          });
        }
        expect(after, '0badf00d-2');
        return jsonResponse(<String, dynamic>{
          'bn': '0badf00d',
          'events': <Object?>[
            <String, dynamic>{'eid': '0badf00d-3', 'type': 'test_result', 'zone': 1, 'ok': true, 'fb_ms': 4200},
          ],
          'more': false,
        });
      });
      final events = await api.fetchEvents();
      expect(events.map((e) => e.eid), <String>['0badf00d-1', '0badf00d-2', '0badf00d-3']);
      expect(events[1].aid, '0badf00d-1');
      expect(events.last.fbMs, 4200);
      expect(mock.requests.length, 2);
    });

    test('yapılandırma yamaları sırayla, rev zinciriyle; 403 local_loosen_forbidden Türkçe metinle durdurur', () async {
      var rev = 7;
      mock.on('POST', '/api/safety/config', (r) {
        final body = r.json!;
        if ((body['del'] as Map?)?['actuator'] == 'a2') {
          return jsonResponse(<String, dynamic>{'error': 'local_loosen_forbidden'}, status: 403);
        }
        expect(body['base_rev'], rev);
        rev++;
        return jsonResponse(<String, dynamic>{'status': 'ok', 'rev': rev, 'crc': '0000000${rev % 10}'});
      });
      final result = await api.applySafetyConfigPatches(<Map<String, dynamic>>[
        <String, dynamic>{
          'set': <String, dynamic>{
            'sensor': <String, dynamic>{'id': 'd3', 'kind': 'water', 'zone': 1, 'active_open': 1},
          },
        },
        <String, dynamic>{
          'set': <String, dynamic>{
            'light': <String, dynamic>{'relay': 8, 'dimmable': 1, 'src': 1, 'addr': 2, 'ch': 1},
          },
        },
      ], baseRev: 7);
      expect(result.rev, 9);
      expect(mock.requests.map((r) => r.json!['base_rev']), <int>[7, 8]);
      await expectLater(
        api.applySafetyConfigPatches(<Map<String, dynamic>>[
          <String, dynamic>{
            'del': <String, dynamic>{'actuator': 'a2'},
          },
        ], baseRev: 9),
        throwsA(isA<LocalApiException>()
            .having((e) => e.code, 'code', 'local_loosen_forbidden')
            .having((e) => e.message, 'message', contains('yerel bağlantıdan yapılamaz'))),
      );
    });

    test('fw-tarama-1 (C1): 400 cfg_invalid detail sensor_bridge_unsupported Türkçe metinle döner', () async {
      mock.on('POST', '/api/safety/config',
          (r) => jsonResponse(<String, dynamic>{'error': 'cfg_invalid', 'detail': 'sensor_bridge_unsupported'}, status: 400));
      await expectLater(
        api.saveSafetyConfig(<String, dynamic>{
          'base_rev': 3,
          'set': <String, dynamic>{
            'sensor': <String, dynamic>{'id': 'b1', 'kind': 'water', 'zone': 1},
          },
        }),
        throwsA(isA<LocalApiException>()
            .having((e) => e.code, 'code', 'cfg_invalid')
            .having((e) => e.message, 'message', 'Kablosuz (köprü) sensör bu panoda desteklenmiyor.')),
      );
    });

    test('504 timeout ve unknown_field Türkçe metne çevrilir', () async {
      mock.on('POST', '/api/alarm/test', (r) => jsonResponse(<String, dynamic>{'error': 'timeout', 'id': 'lan-1'}, status: 504));
      await expectLater(
        api.testAlarm(1),
        throwsA(isA<LocalApiException>().having((e) => e.message, 'message', contains('zamanında işleyemedi'))),
      );
    });
  });

  group('adlar: yapılandırma kopyasından (bulut ve LAN)', () {
    test('bulut: cfg.safety.rev görülünce kopya okunur; sensör ve eylemci adı gösterilir; aynı rev yeniden okunmaz', () async {
      final h = await readyHarness(endpoints: safetyUiEndpoints());
      addTearDown(h.dispose);
      h.cloud.safetyConfigs[kSafetyUid] = <String, dynamic>{
        'rev': 5,
        'crc': '9a3c11f0',
        'sensors': <Object?>[
          <String, dynamic>{'id': 'd3', 'name': 'Evye altı'},
        ],
        'actuators': <Object?>[
          <String, dynamic>{'id': 'a2', 'name': 'Balkon sireni'},
        ],
      };
      h.mqtt.emitStateJson(firmwareState());
      await pumpEventQueue();
      expect(h.state.sensorItems.first.name, 'Evye altı');
      expect(h.state.actuatorItems.firstWhere((a) => a.id == 'a2').name, 'Balkon sireni');
      expect(h.state.actuatorItems.firstWhere((a) => a.id == 'a1').name, 'Ana Su Vanası', reason: 'kopyada ad yoksa uç nokta adı');
      h.mqtt.emitStateJson(firmwareState()..['uptime'] = 99);
      await pumpEventQueue();
      expect(h.cloud.calls.where((c) => c.startsWith('safetyConfig:')).length, 1);
    });

    test('LAN: GET /api/safety/config adları', () async {
      final h = StateHarness();
      addTearDown(h.dispose);
      h.state.setCurrentUserForTesting(const UserModel(id: 'u', email: 'a@b.c', fullName: 'A', role: 'user'));
      h.state.setAuthStatusForTesting(AuthStatus.authenticated);
      h.state.setHomesForTesting(<HomeModel>[testHome()]);
      final status = firmwareState()
        ..remove('v')
        ..remove('uid')
        ..['device'] = kSafetyUid;
      h.directMock
        ..on('GET', '/api/status', (r) => jsonResponse(status))
        ..on('GET', '/api/safety/config', (r) => jsonResponse(<String, dynamic>{
              'rev': 5,
              'crc': '9a3c11f0',
              'sensors': <Object?>[
                <String, dynamic>{'id': 'b1', 'name': 'Banyo'},
              ],
              'actuators': <Object?>[],
            }));
      await h.state.setMode(AppMode.direct);
      await h.state.setHost('192.168.1.30');
      h.direct.localKey = 'devicekey-1234';
      await h.state.refresh();
      expect(h.state.sensorItems.length, greaterThan(1));
      await pumpEventQueue();
      expect(h.state.sensorItems.firstWhere((s) => s.id == 'b1').name, 'Banyo');
    });
  });
}
