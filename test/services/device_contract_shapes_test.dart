import 'dart:convert';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/services/command_pipeline.dart';
import 'package:ev_otomasyon/services/ev_cloud_api_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/support.dart';

/// CONTRACTS §1.5b: B paketinin gerçekleşmiş yanıt şekilleri (çocuk kilidi, claim, sıfırlama, pano
/// değişimi, endpoint takma adları, hata gövdesi ek alanları, komut kimliği).
void main() {
  const credentialJson = <String, dynamic>{
    'host': 'broker.example.test',
    'port': 8884,
    'mqtt_server': 'broker.example.test',
    'mqtt_port': 8884,
    'username': 'd_h_abc123',
    'password': 'sifre-yer-tutucu-xyz123',
    'client_id': 'ESP32S3_AABBCCDDEEFF',
    'topic_id': 'h_abc123',
  };

  group('çocuk kilidi REST şekilleri', () {
    late MockApi api;
    late EvCloudApiService service;

    setUp(() {
      api = MockApi();
      service = EvCloudApiService(baseUrl: 'https://api.test/api', client: api.client, clock: FakeClock())..setAuthToken('jwt');
    });
    tearDown(() => service.dispose());

    test('POST yanıtı: requested/delivered/device_online/command_id/offline_devices; child_lock_enabled YOK', () async {
      api.on(
        'POST',
        '/api/v1/devices/child-lock',
        (r) => okResponse(<String, dynamic>{
          'home_id': kHomeA,
          'requested': true,
          'delivered': true,
          'device_online': true,
          'command_id': 'Ab1_Cd2-Ef3G',
          'offline_devices': <String>['AHBU-S3-B1B1B1'],
        }),
      );
      final result = await service.setChildLock(homeId: kHomeA, enabled: true);
      expect(api.requests.single.json, <String, dynamic>{'home_id': kHomeA, 'enabled': true});
      expect(result.delivered, isTrue);
      expect(result.requested, isTrue);
      expect(result.deviceOnline, isTrue);
      expect(result.commandId, 'Ab1_Cd2-Ef3G');
      expect(result.offlineDevices, <String>['AHBU-S3-B1B1B1']);
      expect(result.noChange, isFalse);
    });

    test('no_change: command_id null; iletildi sayılır ve anında doğrulanmış', () async {
      api.on(
        'POST',
        '/api/v1/devices/child-lock',
        (r) => okResponse(<String, dynamic>{
          'home_id': kHomeA,
          'requested': false,
          'delivered': true,
          'no_change': true,
          'device_online': true,
          'command_id': null,
          'offline_devices': <String>[],
        }),
      );
      final result = await service.setChildLock(homeId: kHomeA, enabled: false);
      expect(result.noChange, isTrue);
      expect(result.commandId, isNull);
      expect(result.delivered, isTrue);
    });

    test('`delivered` alanı yoksa iletildi SAYILMAZ (fail-closed); yanıttaki sahte child_lock_enabled uygulandı demek değildir', () async {
      api.on(
        'POST',
        '/api/v1/devices/child-lock',
        (r) => okResponse(<String, dynamic>{'home_id': kHomeA, 'child_lock_enabled': true, 'requested': true}),
      );
      final result = await service.setChildLock(homeId: kHomeA, enabled: true);
      expect(result.delivered, isFalse);
    });

    test('409 DEVICE_OFFLINE: gövdedeki device_online + offline_devices ApiException\'a taşınır', () async {
      api.on(
        'POST',
        '/api/v1/devices/child-lock',
        (r) => errorResponse(
          409,
          'Pano çevrimdışı; çocuk kilidi komutu iletilemedi.',
          code: 'DEVICE_OFFLINE',
          extra: <String, dynamic>{'device_online': false, 'offline_devices': <String>['AHBU-S3-A1A1A1', 'AHBU-S3-B1B1B1']},
        ),
      );
      try {
        await service.setChildLock(homeId: kHomeA, enabled: true);
        fail('hata bekleniyordu');
      } on ApiException catch (e) {
        expect(e.isDeviceOffline, isTrue);
        expect(e.deviceOnline, isFalse);
        expect(e.offlineDevices, <String>['AHBU-S3-A1A1A1', 'AHBU-S3-B1B1B1']);
      }
    });

    test('429 hız sınırı: retry_after taşınır (ev başına 6/dk + 30/sa)', () async {
      api.on(
        'POST',
        '/api/v1/devices/child-lock',
        (r) => errorResponse(429, 'Çok sık değiştirdiniz.', code: 'RATE_LIMITED', headers: <String, String>{'Retry-After': '30'}, extra: <String, dynamic>{'retry_after': 30}),
      );
      await expectLater(
        service.setChildLock(homeId: kHomeA, enabled: true),
        throwsA(isA<ApiException>().having((e) => e.retryAfter, 'retryAfter', const Duration(seconds: 30))),
      );
    });

    test('GET: child_lock_enabled + requested + requested_at + in_sync + devices[]', () async {
      api.on(
        'GET',
        '/api/v1/devices/child-lock/$kHomeA',
        (r) => okResponse(<String, dynamic>{
          'home_id': kHomeA,
          'child_lock_enabled': false,
          'requested': true,
          'requested_at': '2026-10-01T12:00:00.000Z',
          'in_sync': false,
          'devices': <dynamic>[
            <String, dynamic>{'device_uuid': 'AHBU-S3-A1A1A1', 'online': true, 'child_lock_enabled': false},
            <String, dynamic>{'device_uuid': 'AHBU-S3-B1B1B1', 'online': false, 'child_lock_enabled': true},
            <String, dynamic>{'online': true}, // bozuk satır: atlanır
          ],
        }),
      );
      final info = await service.fetchChildLockInfo(kHomeA);
      expect(info.enabled, isFalse);
      expect(info.requested, isTrue);
      expect(info.requestedAt, DateTime.utc(2026, 10, 1, 12));
      expect(info.inSync, isFalse);
      expect(info.isApplying, isTrue, reason: 'istek (kilitle) ile bildirilen durum (açık) farklı');
      expect(info.devices.map((d) => d.deviceUuid), <String>['AHBU-S3-A1A1A1', 'AHBU-S3-B1B1B1']);
      expect(info.offlineDevices, <String>['AHBU-S3-B1B1B1']);
      expect(await service.getChildLock(kHomeA), isFalse);
    });

    test('GET: hiç istek yoksa requested null; eşleşen istek uygulanıyor sayılmaz', () async {
      api.on(
        'GET',
        '/api/v1/devices/child-lock/$kHomeA',
        (r) => okResponse(<String, dynamic>{'child_lock_enabled': true, 'requested': null, 'requested_at': null, 'in_sync': true, 'devices': <dynamic>[]}),
      );
      final info = await service.fetchChildLockInfo(kHomeA);
      expect(info.requested, isNull);
      expect(info.isApplying, isFalse);

      api.on(
        'GET',
        '/api/v1/devices/child-lock/$kHomeA',
        (r) => okResponse(<String, dynamic>{'child_lock_enabled': true, 'requested': true, 'in_sync': true, 'devices': <dynamic>[]}),
      );
      expect((await service.fetchChildLockInfo(kHomeA)).isApplying, isFalse);
    });

    test('GET: alan yok / hata -> fırlatır ("kilitsiz" sanılmaz)', () async {
      api.on('GET', '/api/v1/devices/child-lock/$kHomeA', (r) => okResponse(<String, dynamic>{'home_id': kHomeA}));
      await expectLater(service.fetchChildLockInfo(kHomeA), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'BAD_RESPONSE')));
      await expectLater(service.getChildLock(kHomeA), throwsA(isA<ApiException>()));
      api.on('GET', '/api/v1/devices/child-lock/$kHomeA', (r) => errorResponse(500, 'iç', code: 'INTERNAL'));
      await expectLater(service.getChildLock(kHomeA), throwsA(isA<ApiException>().having((e) => e.isServerError, 'server', isTrue)));
    });
  });

  group('çocuk kilidi: durum katmanı', () {
    test('POST başarısı: niyet kaydedilir, çevrimdışı panolar listelenir; gerçek durum HÂLÂ cihaz bildirimiyle gelir', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.cloud.setChildLockJson = (home, enabled, id) => <String, dynamic>{
            'home_id': home,
            'requested': enabled,
            'delivered': true,
            'device_online': true,
            'command_id': id,
            'offline_devices': <String>['AHBU-S3-B1B1B1'],
          };
      final dispatch = await h.state.setChildLock(true);
      await pumpEventQueue();

      expect(dispatch.ok, isTrue);
      expect(dispatch.result?.offlineDevices, <String>['AHBU-S3-B1B1B1']);
      expect(h.state.childLockRequested, isTrue);
      expect(h.state.childLockOfflineDevices, <String>['AHBU-S3-B1B1B1']);
      expect(h.state.childLockPending, isTrue, reason: 'iletildi ama cihaz henüz doğrulamadı');
      expect(h.state.childLockAwaitingDevices, isTrue, reason: 'istek (kilitli) ile bilinen durum (açık: REST) farklı: cihazlara uygulanması bekleniyor');

      h.mqtt.emitStateJson(stateJson(childLock: true));
      await pumpEventQueue();
      expect(h.state.childLockStatus, ChildLockStatus.locked);
      expect(h.state.childLockPending, isFalse);
      expect(h.state.childLockAwaitingDevices, isFalse);
    });

    test('`delivered` eksik POST yanıtı: iletildi sayılmaz -> anında geri alma', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      final failures = <CommandFailure>[];
      h.state.commandFailures.listen(failures.add);
      h.cloud.setChildLockJson = (home, enabled, id) => <String, dynamic>{'home_id': home, 'requested': enabled};

      final dispatch = await h.state.setChildLock(true);
      await pumpEventQueue();
      expect(dispatch.ok, isFalse);
      expect(failures.single.reason, CommandFailureReason.notDelivered);
      expect(h.state.childLockStatus, isNot(ChildLockStatus.locked));
      expect(h.state.childLockPending, isFalse);
      expect(h.state.childLockRequested, isNull, reason: 'iletilmeyen istek niyet olarak kaydedilmez');
    });

    test('409 DEVICE_OFFLINE: anında rollback + çevrimdışı pano listesi', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.cloud.setChildLockError = const ApiException(
        statusCode: 409,
        code: 'DEVICE_OFFLINE',
        message: 'Pano çevrimdışı.',
        deviceOnline: false,
        offlineDevices: <String>['AHBU-S3-A1A1A1'],
      );
      final dispatch = await h.state.setChildLock(true);
      await pumpEventQueue();
      expect(dispatch.ok, isFalse);
      expect(dispatch.failure?.reason, CommandFailureReason.offline);
      expect(h.state.childLockOfflineDevices, <String>['AHBU-S3-A1A1A1']);
      expect(h.state.deviceOnline, isFalse);
    });

    test('GET: sunucudaki niyet cihazdan farklıysa "cihazlara uygulanması bekleniyor"; cihaz bildirimi gelince düşer', () async {
      final h = await readyHarness(brokerConnected: false);
      addTearDown(h.dispose);
      h.cloud.childLockValue = false;
      h.cloud.childLockRequestedValue = true;
      h.cloud.childLockDevices = const <ChildLockDeviceInfo>[
        ChildLockDeviceInfo(deviceUuid: 'AHBU-S3-A1A1A1', online: true, enabled: false),
        ChildLockDeviceInfo(deviceUuid: 'AHBU-S3-B1B1B1', online: false, enabled: false),
      ];
      await h.state.refresh(silent: true);
      await pumpEventQueue();

      expect(h.state.childLockStatus, ChildLockStatus.unlocked);
      expect(h.state.childLockRequested, isTrue);
      expect(h.state.childLockAwaitingDevices, isTrue);
      expect(h.state.childLockOfflineDevices, <String>['AHBU-S3-B1B1B1']);

      h.cloud.childLockValue = true; // köprü cihaz bildirimini işledi: birleşik durum ve pano satırları tutarlı
      h.cloud.childLockDevices = const <ChildLockDeviceInfo>[
        ChildLockDeviceInfo(deviceUuid: 'AHBU-S3-A1A1A1', online: true, enabled: true),
        ChildLockDeviceInfo(deviceUuid: 'AHBU-S3-B1B1B1', online: false, enabled: true),
      ];
      await h.state.refresh(silent: true);
      await pumpEventQueue();
      expect(h.state.childLockStatus, ChildLockStatus.locked);
      expect(h.state.childLockAwaitingDevices, isFalse);
    });

    test('çıkış / ev değişimi niyet ve çevrimdışı pano bilgisini sıfırlar', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.cloud.childLockRequestedValue = true;
      h.cloud.childLockDevices = const <ChildLockDeviceInfo>[ChildLockDeviceInfo(deviceUuid: 'AHBU-S3-B1B1B1')];
      await h.state.refresh(silent: true);
      await pumpEventQueue();
      expect(h.state.childLockRequested, isTrue);
      expect(h.state.childLockOfflineDevices, isNotEmpty);

      await h.state.logout();
      expect(h.state.childLockRequested, isNull);
      expect(h.state.childLockOfflineDevices, isEmpty);
    });
  });

  group('device_credential: mqtt_server / mqtt_port ve gizlilik', () {
    test('mqtt_server/mqtt_port tercih edilir; yoksa host/port; LAN gövdesi bunları kullanır', () {
      final preferred = DeviceMqttCredential.fromJson(<String, dynamic>{
        ...credentialJson,
        'host': 'eski.example.test',
        'port': 1883,
        'mqtt_server': 'broker.example.test',
        'mqtt_port': 8884,
      });
      expect(preferred.host, 'broker.example.test');
      expect(preferred.port, 8884);
      expect(preferred.toLanConfigBody()['server'], 'broker.example.test');
      expect(preferred.toLanConfigBody()['port'], 8884);

      final legacy = DeviceMqttCredential.fromJson(<String, dynamic>{
        'host': 'legacy.example.test',
        'port': 8884,
        'username': 'd_x',
        'password': 'p-yer-tutucu',
        'topic_id': 'h_x',
      });
      expect(legacy.host, 'legacy.example.test');
    });

    test('claim sonucu durum katmanından geçse de parola HİÇBİR yere yazılmaz (güvenli depo dahil)', () async {
      final h = await readyHarness(role: 'owner');
      addTearDown(h.dispose);
      h.cloud.claimResultToReturn = ClaimResult.fromJson(<String, dynamic>{
        'home_id': kHomeA,
        'home_name': 'Yeni Ev',
        'device_uuid': 'AHBU-S3-ABC123',
        'device_credential': credentialJson,
      });
      final claim = await h.state.claimDevice('AHBU-S3-ABC123', '123456', homeName: 'Yeni Ev');
      await pumpEventQueue();

      expect(claim.deviceCredential?.password, 'sifre-yer-tutucu-xyz123', reason: 'çağırana (sihirbaza) bir kez döner');
      final stored = h.storage.memory.data.values.join('\n');
      expect(stored, isNot(contains('sifre-yer-tutucu-xyz123')));
      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys()) {
        expect(prefs.get(key).toString(), isNot(contains('sifre-yer-tutucu-xyz123')), reason: key);
      }
      expect(claim.raw.toString(), isNot(contains('sifre-yer-tutucu-xyz123')));
      expect(jsonEncode(claim.raw), isNot(contains('sifre-yer-tutucu-xyz123')));
    });
  });

  group('acil sıfırlama yanıtı', () {
    test('UNCLAIMED: tek seferlik setup_pin; ortak alanlar; uyarı yok', () {
      final result = EmergencyResetResult.fromJson(<String, dynamic>{
        'action': 'UNCLAIMED',
        'device_uuid': 'AHBU-S3-ABC123',
        'home_id': kHomeA,
        'affected_users_count': 3,
        'local_key_publish': 'published',
        'child_lock_reset': 'published',
        'setup_pin': '482915',
        'message': 'Cihaz stoğa alındı.',
      });
      expect(result.isUnclaimed, isTrue);
      expect(result.isReassigned, isFalse);
      expect(result.setupPin, '482915');
      expect(result.affectedUsersCount, 3);
      expect(result.localKeyPublish, 'published');
      expect(result.childLockReset, 'published');
      expect(result.hasWarnings, isFalse);
      expect(result.needsManualLocalKey, isFalse);
      expect(result.deviceCredential, isNull);
    });

    test('REASSIGNED + kısmi başarı (HTTP 200): new_owner, device_credential, local_key, warnings, partial', () {
      final result = EmergencyResetResult.fromJson(<String, dynamic>{
        'action': 'reassigned',
        'device_uuid': 'AHBU-S3-ABC123',
        'home_id': kHomeA,
        'affected_users_count': 2,
        'local_key_publish': 'skipped_offline',
        'child_lock_reset': 'failed',
        'new_owner': <String, dynamic>{'id': 'u-9', 'full_name': 'Yeni Sahip'},
        'device_credential': credentialJson,
        'local_key': 'cihaza-yazilacak-anahtar-1',
        'warnings': <String>['Cihaz çevrimdışı; yeni yerel anahtar iletilemedi.', 'Eski bağlantılar atılamadı.'],
        'partial': true,
        'message': 'Cihaz yeni sahibe devredildi.',
      });
      expect(result.isReassigned, isTrue, reason: 'action büyük harfe normalleştirilir');
      expect(result.newOwner?.id, 'u-9');
      expect(result.newOwner?.fullName, 'Yeni Sahip');
      expect(result.deviceCredential?.username, 'd_h_abc123');
      expect(result.localKey, 'cihaza-yazilacak-anahtar-1');
      expect(result.needsManualLocalKey, isTrue);
      expect(result.hasWarnings, isTrue);
      expect(result.partial, isTrue);
      expect(result.warnings, hasLength(2));
      expect(result.localKeyPublish, 'skipped_offline');
      expect(result.childLockReset, 'failed');
    });

    test('toString gizli değerleri (PIN, yerel anahtar, parola) içermez', () {
      final result = EmergencyResetResult.fromJson(<String, dynamic>{
        'action': 'REASSIGNED',
        'device_uuid': 'AHBU-S3-ABC123',
        'setup_pin': '482915',
        'local_key': 'cihaza-yazilacak-anahtar-1',
        'device_credential': credentialJson,
      });
      final text = result.toString();
      expect(text, isNot(contains('482915')));
      expect(text, isNot(contains('cihaza-yazilacak-anahtar-1')));
      expect(text, isNot(contains('sifre-yer-tutucu-xyz123')));
    });

    test('bozuk new_owner / device_credential çökertmez', () {
      final result = EmergencyResetResult.fromJson(<String, dynamic>{
        'action': 'REASSIGNED',
        'new_owner': <String, dynamic>{'full_name': 'Kimliksiz'},
        'device_credential': <String, dynamic>{'host': 'x'},
      });
      expect(result.newOwner, isNull);
      expect(result.deviceCredential, isNull);
    });

    test('durum katmanı tipli sonucu döndürür ve ev listesini yeniler', () async {
      final h = await readyHarness(role: 'owner', globalRole: 'super_user');
      addTearDown(h.dispose);
      h.cloud.emergencyResetToReturn = EmergencyResetResult.fromJson(<String, dynamic>{
        'action': 'UNCLAIMED',
        'device_uuid': 'AHBU-S3-ABC123',
        'setup_pin': '482915',
        'warnings': <String>['Eski bağlantılar atılamadı.'],
        'partial': true,
      });
      final fetches = h.cloud.count('fetchHomes');
      final result = await h.state.emergencyResetDevice(
        deviceUuid: 'AHBU-S3-ABC123',
        confirmUid: 'AHBU-S3-ABC123',
        reason: 'Kiracıya ulaşılamıyor, kimlik doğrulandı.',
      );
      expect(result.hasWarnings, isTrue);
      expect(result.setupPin, '482915');
      expect(h.cloud.count('fetchHomes'), greaterThan(fetches));
    });
  });

  group('pano değişimi yanıtı', () {
    test('tam yanıt: eski/yeni uuid, taşınan kanal sayısı, kimlik, panjur süreleri, kilit senkronu', () {
      final result = ReplaceBoardResult.fromJson(<String, dynamic>{
        'message': 'Pano değişimi tamamlandı.',
        'old_device_uuid': 'AHBU-S3-OLD111',
        'new_device_uuid': 'AHBU-S3-NEW222',
        'migrated_endpoints_count': 12,
        'home_id': kHomeA,
        'device_credential': credentialJson,
        'shutter_runtimes': <dynamic>[
          <String, dynamic>{'shutter': 1, 'sec': 24},
          <String, dynamic>{'shutter': 2, 'sec': 18},
          <String, dynamic>{'shutter': 0, 'sec': 10}, // bozuk: atlanır
          <String, dynamic>{'shutter': 3, 'sec': 999}, // aralık dışı: atlanır
        ],
        'runtime_sync': 'pending_device_online',
        'child_lock': <String, dynamic>{'enabled': true, 'sync': 'pending_device_online'},
        'warnings': <String>['Eski pano bağlantısı atılamadı; kimlik yenilendi.'],
      });
      expect(result.oldDeviceUuid, 'AHBU-S3-OLD111');
      expect(result.newDeviceUuid, 'AHBU-S3-NEW222');
      expect(result.migratedEndpointsCount, 12, reason: 'arayüz camelCase `migratedEndpointsCount` bekliyordu; sunucu snake_case');
      expect(result.deviceCredential?.topicId, 'h_abc123');
      expect(result.shutterRuntimes.map((s) => (s.shutter, s.seconds)), <(int, int)>[(1, 24), (2, 18)]);
      expect(result.runtimeSync, 'pending_device_online');
      expect(result.childLockEnabled, isTrue);
      expect(result.childLockPending, isTrue);
      expect(result.hasWarnings, isTrue);
      expect(result.toString(), isNot(contains('sifre-yer-tutucu-xyz123')));
    });

    test('yeni pano kimliği yoksa FormatException; kilit gerekmiyorsa pending değil', () {
      expect(() => ReplaceBoardResult.fromJson(<String, dynamic>{'message': 'x'}), throwsFormatException);
      final result = ReplaceBoardResult.fromJson(<String, dynamic>{
        'new_device_uuid': 'AHBU-S3-NEW222',
        'child_lock': <String, dynamic>{'enabled': false, 'sync': 'not_required'},
      });
      expect(result.childLockPending, isFalse);
      expect(result.hasWarnings, isFalse);
    });

    test('bulut istemcisi ve durum katmanı tipli sonuç döndürür', () async {
      final api = MockApi()
        ..on(
          'POST',
          '/api/v1/devices/replace-board',
          (r) => okResponse(<String, dynamic>{
            'message': 'Pano değişimi tamamlandı.',
            'old_device_uuid': 'AHBU-S3-OLD111',
            'new_device_uuid': 'AHBU-S3-NEW222',
            'migrated_endpoints_count': 8,
            'home_id': kHomeA,
            'device_credential': credentialJson,
            'shutter_runtimes': <dynamic>[],
            'runtime_sync': 'pending_device_online',
            'child_lock': <String, dynamic>{'enabled': false, 'sync': 'not_required'},
          }),
        );
      final service = EvCloudApiService(baseUrl: 'https://api.test/api', client: api.client, clock: FakeClock())..setAuthToken('jwt');
      addTearDown(service.dispose);
      final result = await service.replaceBoard(homeId: kHomeA, newDeviceUuid: 'ahbu-s3-new222', setupPin: ' 123456 ', oldDeviceUuid: 'ahbu-s3-old111');
      expect(api.requests.single.json, <String, dynamic>{
        'home_id': kHomeA,
        'new_device_uuid': 'AHBU-S3-NEW222',
        'setup_pin': '123456',
        'old_device_uuid': 'AHBU-S3-OLD111',
      });
      expect(result.migratedEndpointsCount, 8);

      final h = await readyHarness(role: 'owner');
      addTearDown(h.dispose);
      h.cloud.replaceBoardToReturn = result;
      final viaState = await h.state.replaceBoard(newDeviceUuid: 'AHBU-S3-NEW222', setupPin: '123456');
      expect(viaState.newDeviceUuid, 'AHBU-S3-NEW222');
    });
  });

  group('endpoint JSON takma adları', () {
    test('channel / endpoint_type / shutter_position / online takma adları okunur', () {
      final endpoint = EndpointModel.fromJson(<String, dynamic>{
        'id': 'e1',
        'home_id': kHomeA,
        'device_uuid': 'AHBU-S3-ABC123',
        'channel': 3,
        'endpoint_type': 'shutter',
        'shutter_position': 40,
        'shutter_pair_index': 2,
        'online': true,
        'name': 'Salon Panjur Yukarı',
        'room': 'Salon',
      });
      expect(endpoint.channel, 3);
      expect(endpoint.endpointType, 'shutter');
      expect(endpoint.shutterPosition, 40);
      expect(endpoint.pair, 2);
      expect(endpoint.deviceOnline, isTrue);
    });

    test('asıl alanlar takma adlardan önce gelir; device_online `online`dan önce', () {
      final endpoint = EndpointModel.fromJson(<String, dynamic>{
        'id': 'e1',
        'channel_index': 5,
        'channel': 9,
        'type': 'light',
        'endpoint_type': 'plug',
        'current_position': 10,
        'shutter_position': 90,
        'device_online': false,
        'online': true,
      });
      expect(endpoint.channel, 5);
      expect(endpoint.endpointType, 'light');
      expect(endpoint.shutterPosition, 10);
      expect(endpoint.deviceOnline, isFalse);
    });
  });

  group('hata gövdesi ek alanları', () {
    test('retry_after, remaining_attempts, device_online, offline_devices birlikte', () async {
      final api = MockApi()
        ..on(
          'POST',
          '/api/v1/devices/claim',
          (r) => errorResponse(
            400,
            'Hatalı doğrulama kodu. Kalan deneme hakkı: 2',
            code: 'VALIDATION',
            extra: <String, dynamic>{
              'remaining_attempts': 2,
              'retry_after': 90,
              'device_online': false,
              'offline_devices': <dynamic>['AHBU-S3-A1A1A1', '', 7],
            },
          ),
        );
      final service = EvCloudApiService(baseUrl: 'https://api.test/api', client: api.client, clock: FakeClock())..setAuthToken('jwt');
      addTearDown(service.dispose);
      try {
        await service.claimDevice(deviceUuid: 'AHBU-S3-ABC123', setupPin: '123456');
        fail('hata bekleniyordu');
      } on ApiException catch (e) {
        expect(e.remainingAttempts, 2);
        expect(e.retryAfter, const Duration(seconds: 90));
        expect(e.deviceOnline, isFalse);
        expect(e.offlineDevices, <String>['AHBU-S3-A1A1A1', '7']);
      }
    });

    test('ek alan yoksa varsayılanlar (null / boş liste)', () {
      const error = ApiException(statusCode: 400, message: 'm');
      expect(error.deviceOnline, isNull);
      expect(error.offlineDevices, isEmpty);
      expect(error.remainingAttempts, isNull);
    });
  });

  group('komut kimliği: ^[A-Za-z0-9._:-]{1,24}\$', () {
    final pattern = RegExp(r'^[A-Za-z0-9._:-]{1,24}$');

    test('istemcinin ürettiği komut kimlikleri kurala uyar (röle, panjur, toplu, çocuk kilidi)', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      await h.state.setRelay(1, true);
      await h.state.setShutterPosition(2, 40);
      await h.state.cmdShutter(2, 'up');
      await h.state.cmdAll('lightsoff');
      await h.state.setChildLock(true);
      await h.clock.elapse(const Duration(seconds: 12));

      final commands = h.cloud.sentCommands;
      expect(commands, isNotEmpty);
      for (final command in commands) {
        final id = command['id'];
        if (id == null) continue; // id yollamamak da geçerli
        expect(id, isA<String>());
        expect(pattern.hasMatch(id as String), isTrue, reason: 'id=$id');
      }
      expect(commands.any((c) => c['id'] != null), isTrue, reason: 'komutlar geri yankı için id taşır');
    });

    test('boru hattı kimlik üreteci: çok sayıda ve uzak gelecekteki saatte de kurala uyar, benzersizdir', () {
      final clock = FakeClock(DateTime.utc(2100, 1, 1));
      final pipeline = CommandPipeline(clock: clock);
      addTearDown(pipeline.dispose);
      final ids = <String>{};
      for (var i = 0; i < 5000; i++) {
        final entry = pipeline.nextCommandIdForTesting();
        expect(pattern.hasMatch(entry), isTrue, reason: entry);
        ids.add(entry);
      }
      expect(ids.length, 5000);
    });
  });
}
