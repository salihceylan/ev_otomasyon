import 'package:ev_otomasyon/services/api_exception.dart';
import 'package:ev_otomasyon/services/ev_cloud_api_service.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/logic/safety_config_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';

/// Faz 2 WP-C3 (tasarım F2.D.1-D.5): bulut taşımasının istek/yanıt eşlemesi.
void main() {
  late FakeClock clock;
  late FakeCloudApi cloud;
  late CloudSafetyConfigTransport transport;

  setUp(() {
    clock = FakeClock();
    cloud = FakeCloudApi(clock: clock);
    transport = CloudSafetyConfigTransport(
      cloud: cloud,
      homeId: kHomeA,
      deviceId: 'AHBU-S3-TEST01',
      clock: clock,
      delay: (d) async => clock.advance(d),
    );
  });

  const set1 = <String, dynamic>{
    'set': <String, dynamic>{
      'sensor': <String, dynamic>{'id': 'd5', 'kind': 'door', 'zone': 1, 'active_open': 1},
    },
  };
  const set2 = <String, dynamic>{
    'del': <String, dynamic>{'sensor': 'd6'},
  };

  test('read: kopya panonun rev\'ine ulaşana kadar bekler (en çok 15 sn); bekleyen kuyruk okunur', () async {
    var calls = 0;
    cloud.safetyConfigHandler = (home, device) async {
      calls++;
      return <String, dynamic>{
        'rev': calls < 3 ? 6 : 7,
        'state_rev': 7,
        'next_base_rev': 7,
        'pending': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'c1', 'op': 'set', 'item': 'sensor', 'target': 'd5', 'at': '2026-10-07T03:00:00Z', 'role': 'owner'},
        ],
      };
    };
    final data = await transport.read();
    expect(data['rev'], 7);
    expect(calls, 3);
    expect(transport.pending.single.target, 'd5');
    expect(transport.nextBaseRev, 7);
  });

  test('read: 15 sn içinde ulaşmazsa "Pano yapılandırması okunuyor…"', () async {
    cloud.safetyConfigHandler = (home, device) async => <String, dynamic>{'rev': 6, 'state_rev': 7};
    await expectLater(
      transport.read(),
      throwsA(isA<ApiException>().having((e) => e.message, 'message', contains('okunuyor'))),
    );
  });

  test('apply: sırayla, her yama bir öncekinin rev\'iyle; gövde {base_rev, set|del, id}', () async {
    cloud.patchHandler = (call) async => <String, dynamic>{'applied': true, 'rev': call.baseRev + 1, 'command_id': call.commandId};
    final result = await transport.apply(<Map<String, dynamic>>[set1, set2], baseRev: 7);
    expect(result.applied, isTrue);
    expect(result.rev, 9);
    expect(cloud.patchCalls.map((c) => c.baseRev), <int>[7, 8]);
    expect(cloud.patchCalls.first.patch, set1);
    expect(cloud.patchCalls.map((c) => c.commandId).toSet(), hasLength(2));
  });

  test('apply: pano çevrimdışı -> 202 queued; zincir base_rev + 1 ile sürer; adım tamamlanmış sayılmaz', () async {
    cloud.patchHandler = (call) async => <String, dynamic>{
          'queued': true,
          'position': cloud.patchCalls.length,
          'expires_at': '2026-10-08T03:00:00Z',
          'command_id': call.commandId,
        };
    final result = await transport.apply(<Map<String, dynamic>>[set1, set2], baseRev: 7);
    expect(result.queued, isTrue);
    expect(result.applied, isFalse);
    expect(result.position, 2);
    expect(cloud.patchCalls.map((c) => c.baseRev), <int>[7, 8]);
  });

  test('apply: 202 applied:null -> kalan yamalar gönderilmez, doğrulanmadı', () async {
    cloud.patchHandler = (call) async => <String, dynamic>{'applied': null, 'command_id': call.commandId};
    final result = await transport.apply(<Map<String, dynamic>>[set1, set2], baseRev: 7);
    expect(result.unconfirmed, isTrue);
    expect(cloud.patchCalls, hasLength(1));
  });

  test('apply: 409 CONFIG_CHANGED_ON_DEVICE -> SafetyConfigConflict(rev)', () async {
    cloud.patchHandler = (call) async => throw ApiException(
          statusCode: 409,
          code: 'CONFIG_CHANGED_ON_DEVICE',
          message: ApiException.clientMessages['CONFIG_CHANGED_ON_DEVICE']!,
          details: const <String, dynamic>{
            'data': <String, dynamic>{'rev': 11, 'crc': 'abcd', 'copy_rev': 9},
          },
        );
    await expectLater(
      transport.apply(<Map<String, dynamic>>[set1], baseRev: 7),
      throwsA(isA<SafetyConfigConflict>().having((e) => e.rev, 'rev', 11)),
    );
  });

  test('istemci: POST …/safety-config ve DELETE …/pending yolları, gövde ve 202 gövdesi', () async {
    final api = MockApi();
    final service = EvCloudApiService(baseUrl: 'https://api.test/api', client: api.client, clock: FakeClock());
    addTearDown(service.dispose);
    api.on('POST', RegExp(r'/safety-config$'), (r) => jsonResponse(<String, dynamic>{
          'success': true,
          'data': <String, dynamic>{'queued': true, 'position': 1, 'expires_at': '2026-10-08T03:00:00Z', 'command_id': 'x'},
        }, status: 202));
    api.on('DELETE', RegExp(r'/safety-config/pending$'), (r) => jsonResponse(<String, dynamic>{
          'success': true,
          'data': <String, dynamic>{'dropped': 2},
        }));
    final res = await service.patchSafetyConfig(
      homeId: kHomeA,
      deviceId: 'AHBU-S3-TEST01',
      baseRev: 7,
      patch: set1,
      commandId: 'cmd-1',
    );
    expect(res['queued'], isTrue);
    final post = api.requests.first;
    expect(post.url.path, '/api/v1/homes/$kHomeA/devices/AHBU-S3-TEST01/safety-config');
    expect(post.json, <String, dynamic>{...set1, 'base_rev': 7, 'id': 'cmd-1'});
    expect(await service.clearSafetyConfigPending(kHomeA, 'AHBU-S3-TEST01'), 2);
  });

  // Faz 2 incelemesi G-1: bulut yolunun yetki sınırı kodları uygulamanın kendi Türkçe metniyle gösterilir.
  test('istemci: 403 GAS_VALVE_LOCAL_ONLY ve 409 INTRUSION_ARMED uygulama metniyle (G-1)', () async {
    final api = MockApi();
    final service = EvCloudApiService(baseUrl: 'https://api.test/api', client: api.client, clock: FakeClock());
    addTearDown(service.dispose);
    var code = 'GAS_VALVE_LOCAL_ONLY';
    api.on('POST', RegExp(r'/safety-config$'), (r) => jsonResponse(<String, dynamic>{
          'success': false,
          'code': code,
          'message': 'server text',
        }, status: code == 'GAS_VALVE_LOCAL_ONLY' ? 403 : 409));
    Future<void> expectText(String text) => expectLater(
          service.patchSafetyConfig(homeId: kHomeA, deviceId: 'AHBU-S3-TEST01', baseRev: 7, patch: set1, commandId: 'c'),
          throwsA(isA<ApiException>().having((e) => e.code, 'code', code).having((e) => e.message, 'message', text)),
        );
    await expectText(ApiException.clientMessages['GAS_VALVE_LOCAL_ONLY']!);
    expect(ApiException.clientMessages['GAS_VALVE_LOCAL_ONLY'], contains('gaz vanası'));
    code = 'INTRUSION_ARMED';
    await expectText(ApiException.clientMessages['INTRUSION_ARMED']!);
    expect(ApiException.clientMessages['INTRUSION_ARMED'], contains('Alarm kurulu'));
  });
}
