import 'dart:convert';
import 'dart:io';

import 'package:ev_otomasyon/models/automation_models.dart';
import 'package:ev_otomasyon/models/capabilities.dart';
import 'package:ev_otomasyon/models/install_template_models.dart';
import 'package:ev_otomasyon/services/api_exception.dart';
import 'package:ev_otomasyon/services/automation_api_service.dart';
import 'package:ev_otomasyon/services/ev_cloud_api_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';

/// İP-4.1 / İP-4.2: kurulum şablonu bulut + yerel API'si ve durum modelindeki yeni alanlar (CONTRACTS §3e).
void main() {
  group('bulut: site / şablon / yazım kaydı', () {
    late MockApi api;
    late EvCloudApiService service;
    setUp(() {
      api = MockApi();
      service = EvCloudApiService(baseUrl: 'https://api.test/api', client: api.client, clock: FakeClock())..setAuthToken('t');
    });
    tearDown(() => service.dispose());

    test('siteler: GET /v1/sites; bozuk satır atlanır', () async {
      api.on('GET', '/api/v1/sites', (r) => okResponse(<Object?>[
            <String, dynamic>{'id': 's1', 'name': 'Güneş Sitesi', 'city': 'Ankara', 'district': 'Çankaya', 'flat_count': 48},
            <String, dynamic>{'name': 'kimliksiz'},
          ]));
      final sites = await service.listInstallSites();
      expect(sites, hasLength(1));
      expect(sites.single.name, 'Güneş Sitesi');
      expect(sites.single.place, 'Çankaya / Ankara');
      expect(sites.single.flatCount, 48);
    });

    test('şablon listesi: site_id + include_global sorgusu; `templates` anahtarlı yanıt da okunur', () async {
      api.on('GET', '/api/v1/templates', (r) => okResponse(<String, dynamic>{
            'templates': <Object?>[
              <String, dynamic>{'id': 't1', 'site_id': 's1', 'name': 'A 2+1', 'flat_type': '2+1', 'current_version': 3},
              <String, dynamic>{'id': 't2', 'site_id': null, 'name': 'Standart', 'flat_type': '1+1', 'current_version': 1},
            ],
          }));
      final list = await service.listInstallTemplates(siteId: 's1');
      final req = api.requests.single;
      expect(req.url.queryParameters, <String, String>{'site_id': 's1', 'include_global': '1'});
      expect(list.map((t) => t.id), <String>['t1', 't2']);
      expect(list.first.currentVersion, 3);
      expect(list.last.isGlobal, isTrue);

      await service.listInstallTemplates(includeGlobal: true);
      expect(api.requests.last.url.queryParameters, <String, String>{'include_global': '1'});
    });

    test('şablon gövdesi: GET /v1/templates/:id -> {..., body}; sürüm meta.version', () async {
      final body = _fixture('ok_3p1_vana_dimmer.json');
      api.on('GET', RegExp(r'/api/v1/templates/[^/]+$'), (r) => okResponse(<String, dynamic>{
            'id': 'row-1',
            'site_id': 's1',
            'name': 'B Tipi 3+1',
            'flat_type': '3+1',
            'current_version': 4,
            'body': body,
          }));
      final tpl = await service.installTemplate('row-1');
      expect(api.requests.single.path, '/api/v1/templates/row-1');
      expect(tpl.version, 4);
      expect(tpl.templateId, '3f2a9c1e-5b7d-4e8f-9a01-23456789abcd');
      expect(tpl.body, body, reason: 'gövde değiştirilmeden taşınır');
    });

    test('gövdesiz yanıt BAD_RESPONSE olur', () async {
      api.on('GET', RegExp(r'/api/v1/templates/[^/]+$'), (r) => okResponse(<String, dynamic>{'id': 'x', 'name': 'y'}));
      await expectLater(service.installTemplate('x'), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'BAD_RESPONSE')));
    });

    test('yazım kaydı: POST /v1/template-writes {via: "lan", result, error_code?}', () async {
      api.on('POST', '/api/v1/template-writes', (r) => okResponse(<String, dynamic>{'id': 1}, status: 201));
      await service.recordTemplateWrite(deviceUuid: 'AHBU-S3-A1', templateId: 't1', version: 4, via: 'lan', ok: true);
      await service.recordTemplateWrite(
        deviceUuid: 'AHBU-S3-A1',
        templateId: 't1',
        version: 4,
        via: 'lan',
        ok: false,
        errorCode: 'local_loosen_forbidden',
      );
      expect(api.requests[0].json, <String, dynamic>{
        'device_uuid': 'AHBU-S3-A1',
        'template_id': 't1',
        'version': 4,
        'via': 'lan',
        'result': 'ok',
      });
      expect(api.requests[1].json?['result'], 'error');
      expect(api.requests[1].json?['error_code'], 'local_loosen_forbidden');
    });
  });

  group('yerel: GET /api/template, POST /api/template/apply', () {
    late MockApi mock;
    late AutomationApiService api;
    setUp(() {
      mock = MockApi();
      api = AutomationApiService(baseUrl: 'http://192.168.1.30', localKey: 'devicekey-1234', client: mock.client, clock: FakeClock());
    });

    test('yüklü şablon okunur (anahtarlı)', () async {
      mock.on('GET', '/api/template', (r) => jsonResponse(<String, dynamic>{
            'template_id': 'tpl-1',
            'version': 4,
            'label': 'Güneş A-12',
            'applied_at_uptime_s': 120,
          }));
      final info = await api.fetchTemplate();
      expect(mock.requests.single.headers['X-Device-Key'], 'devicekey-1234');
      expect(info.hasTemplate, isTrue);
      expect(info.version, 4);
      expect(info.label, 'Güneş A-12');
    });

    test('şablonsuz pano: template_id null', () async {
      mock.on('GET', '/api/template', (r) => jsonResponse(<String, dynamic>{'template_id': null, 'version': 0, 'label': ''}));
      expect((await api.fetchTemplate()).hasTemplate, isFalse);
    });

    test('eski firmware: 404 (ucu yok)', () async {
      await expectLater(api.fetchTemplate(), throwsA(isA<LocalApiException>().having((e) => e.statusCode, 'status', 404)));
    });

    test('uygulama: zarf olduğu gibi gönderilir, yanıt okunur', () async {
      mock.on('POST', '/api/template/apply', (r) => jsonResponse(<String, dynamic>{
            'ok': true,
            'template_id': 'tpl-1',
            'version': 4,
            'rev': 9,
          }));
      final envelope = <String, dynamic>{
        'template': <String, dynamic>{'schema': 'ahbu-template/1'},
        'label': 'Daire 5',
      };
      final result = await api.applyTemplate(envelope);
      expect(mock.requests.single.json, envelope);
      expect(result.version, 4);
      expect(result.rev, 9);
    });

    test('202 {pending:true} hata değildir: pending işaretlenir', () async {
      mock.on('POST', '/api/template/apply', (r) => jsonResponse(<String, dynamic>{'pending': true}, status: 202));
      final result = await api.applyTemplate(<String, dynamic>{'template': <String, dynamic>{}});
      expect(result.pending, isTrue);
    });

    for (final c in <(int, String, String?)>[
      (403, 'local_loosen_forbidden', null),
      (409, 'zone_latched', null),
      (409, 'armed', null),
      (409, 'busy', null),
      (507, 'storage', null),
      (400, 'invalid_runtime', 'relays[3].runtime_s'),
    ]) {
      test('ret ${c.$1} ${c.$2} -> LocalApiException (kod${c.$3 == null ? '' : ' + path'})', () async {
        mock.on('POST', '/api/template/apply', (r) => jsonResponse(<String, dynamic>{'error': c.$2, 'path': ?c.$3}, status: c.$1));
        try {
          await api.applyTemplate(<String, dynamic>{'template': <String, dynamic>{}});
          fail('hata bekleniyordu');
        } on LocalApiException catch (e) {
          expect(e.statusCode, c.$1);
          expect(e.code, c.$2);
          expect(e.path, c.$3);
          expect(e.message, isNot(contains('Kod:')), reason: 'Türkçe metin: ${e.message}');
        }
      });
    }
  });

  group('durum modeli: tpl / eth_* (eski firmware geriye uyumlu)', () {
    test('eski yanıt (alan yok) eskisi gibi ayrıştırılır', () {
      final s = DeviceStatus.fromJson(<String, dynamic>{
        'device': 'AHBU-S3-A1B2C3',
        'ip': '192.168.1.42',
        'wifi_connected': true,
        'relays': <Object?>[<String, dynamic>{'id': 1, 'name': 'L1', 'type': 0, 'state': false}],
      });
      expect(s.template, isNull);
      expect(s.ethConnected, isNull);
      expect(s.ethIp, '');
      expect(s.netIf, isNull);
      expect(s.relays, hasLength(1));
    });

    test('yeni yanıt: tpl {id, ver}, eth_connected, eth_ip, net_if', () {
      final s = DeviceStatus.fromJson(<String, dynamic>{
        'device': 'AHBU-S3-A1B2C3',
        'ip': '192.168.1.77',
        'tpl': <String, dynamic>{'id': 'tpl-1', 'ver': 4},
        'eth_connected': true,
        'eth_ip': '192.168.1.77',
        'net_if': 'eth',
        'relays': <Object?>[],
      });
      expect(s.template, const TemplateRef(id: 'tpl-1', version: 4));
      expect(s.ethConnected, isTrue);
      expect(s.ethIp, '192.168.1.77');
      expect(s.netIf, 'eth');
      expect(s.copyWith(childLock: true).template, s.template, reason: 'copyWith alanı korur');
    });

    test('bozuk tpl yok sayılır; sameAs şablon değişimini görür', () {
      final a = DeviceStatus.fromJson(<String, dynamic>{'tpl': 'bozuk', 'relays': <Object?>[]});
      expect(a.template, isNull);
      final b = DeviceStatus.fromJson(<String, dynamic>{'tpl': <String, dynamic>{'id': 'x', 'ver': 1}, 'relays': <Object?>[]});
      expect(a.sameAs(b), isFalse);
    });
  });

  group('önizleme (ortak örnek dosyalar)', () {
    test('ok_3p1_vana_dimmer: 4 lamba, 2 panjur, 8 giriş, 2 sensör, 1 vana, 1 dimmer', () {
      final p = TemplatePreview.of(_fixture('ok_3p1_vana_dimmer.json'));
      expect(p.relayCount, 8);
      expect(p.lights, 4);
      expect(p.shutters, 2);
      expect(p.inputs, 8);
      expect(p.sensors, 2);
      expect(p.actuators, 1);
      expect(p.dimmers, 1);
      expect(p.flatType, '3+1');
      expect(p.hasSafety, isTrue);
    });

    test('ok_dubleks_ekmodul16: ek modül kanalları sayılır (8 + 8)', () {
      final body = _fixture('ok_dubleks_ekmodul16.json');
      final p = TemplatePreview.of(body);
      expect(p.extChannels, 8);
      expect(p.relayCount, 16);
    });
  });

  group('yetki: canUseInstallTemplates (K-Ş7)', () {
    test('süper ve küresel servis personeli ✔; servis oturumu, ev sahibi, sakin ✖', () {
      expect(Capabilities(globalRole: 'super_user').canUseInstallTemplates, isTrue);
      expect(Capabilities(globalRole: 'service_user').canUseInstallTemplates, isTrue);
      expect(Capabilities(globalRole: 'service_session', homeRole: 'service_session').canUseInstallTemplates, isFalse);
      expect(Capabilities(globalRole: 'user', homeRole: 'owner').canUseInstallTemplates, isFalse);
      expect(Capabilities(globalRole: 'user', homeRole: 'service_user').canUseInstallTemplates, isFalse);
      expect(const Capabilities.localKeyHolder().canUseInstallTemplates, isFalse);
    });
  });
}

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('docs/contracts/template/fixtures/$name').readAsStringSync()) as Map<String, dynamic>;
