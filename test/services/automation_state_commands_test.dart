import 'dart:async';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/capabilities.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/services/ev_mqtt_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/support.dart';

void main() {
  late List<CommandFailure> failures;
  setUp(() => failures = <CommandFailure>[]);

  group('bulut: röle komutları', () {
    test('toggleRelay: açık state (toggle değil) + id, iyimser değer anında, cihaz onayıyla kalıcı', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.state.commandFailures.listen(failures.add);
      expect(ep(h.state, 1).currentState, isFalse);

      final result = h.state.toggleRelay(1);
      expect(ep(h.state, 1).currentState, isTrue, reason: 'iyimser: REST yanıtı gelmeden görünür');
      expect(await result, isTrue);

      final cmd = h.cloud.sentCommands.single;
      expect(cmd['relay'], 1);
      expect(cmd['state'], true);
      expect(cmd.containsKey('cmd'), isFalse, reason: 'toggle yerine açık hedef durum');
      expect(cmd['id'], isA<String>());
      expect((cmd['id'] as String).length, lessThanOrEqualTo(24));
      expect(h.cloud.calls, contains('sendCommand:AHBU-S3-TEST01'));
      expect(h.state.commandPipeline.isPending('relay:1'), isTrue);

      h.mqtt.emitStateJson(stateJson(relays: <int, bool>{1: true}));
      await pumpEventQueue();
      expect(h.state.commandPipeline.hasPending, isFalse);
      expect(ep(h.state, 1).currentState, isTrue);
      await h.clock.elapse(const Duration(seconds: 10));
      expect(failures, isEmpty);
      expect(ep(h.state, 1).currentState, isTrue);
    });

    test('2.5 sn içinde onay yoksa GERİ ALINIR + snackbar olayı', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.state.commandFailures.listen(failures.add);
      await h.state.toggleRelay(1);
      expect(ep(h.state, 1).currentState, isTrue);
      await h.clock.elapse(const Duration(milliseconds: 2400));
      expect(ep(h.state, 1).currentState, isTrue);
      await h.clock.elapse(const Duration(milliseconds: 300));
      expect(ep(h.state, 1).currentState, isFalse, reason: 'gerçek değere dönüldü');
      expect(failures, hasLength(1));
      expect(failures.single.reason, CommandFailureReason.timeout);
    });

    test('409 DEVICE_OFFLINE -> anında geri alma; cihaz çevrimdışı olarak işaretlenir', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.state.commandFailures.listen(failures.add);
      h.cloud.sendCommandHandler = (home, device, command) async =>
          throw const ApiException(statusCode: 409, code: 'DEVICE_OFFLINE', message: 'Cihaz çevrimdışı');
      expect(h.state.devicePresence, DevicePresence.online);

      expect(await h.state.toggleRelay(2), isFalse);
      await pumpEventQueue();
      expect(ep(h.state, 2).currentState, isFalse);
      expect(failures.single.reason, CommandFailureReason.offline);
      expect(h.state.devicePresence, DevicePresence.offline);
      expect(h.state.deviceOnline, isFalse);
      expect(h.state.brokerConnected, isTrue, reason: 'broker bağlantısı cihaz çevrimiçiliğinden AYRI alan');
      expect(h.state.isConnected, isFalse);
    });

    test('delivered=false -> anında geri alma', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.state.commandFailures.listen(failures.add);
      h.cloud.sendCommandHandler = (home, device, command) async => const CommandResult(delivered: false);
      expect(await h.state.setRelay(1, true), isFalse);
      await pumpEventQueue();
      expect(ep(h.state, 1).currentState, isFalse);
      expect(failures.single.reason, CommandFailureReason.notDelivered);
    });

    test('çift basış: tek bekleyen komut, son niyet kazanır, gönderimler sıralı', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      final gate = Completer<void>();
      var calls = 0;
      h.cloud.sendCommandHandler = (home, device, command) async {
        calls++;
        if (calls == 1) await gate.future;
        return CommandResult(delivered: true, deviceOnline: true, commandId: command['id'] as String?);
      };
      final first = h.state.toggleRelay(1); // görünür: kapalı -> açık
      expect(ep(h.state, 1).currentState, isTrue);
      final second = h.state.toggleRelay(1); // görünür: açık -> kapalı
      expect(ep(h.state, 1).currentState, isFalse);
      expect(h.state.commandPipeline.pending, hasLength(1));
      expect(h.state.commandPipeline.pendingFor('relay:1')!.original, false, reason: 'ilk dokunuştaki gerçek değer');

      gate.complete();
      expect(await first, isFalse, reason: 'ilk komut yerini yenisine bıraktı');
      expect(await second, isTrue);
      expect(h.cloud.sentCommands.map((c) => c['state']), <Object?>[true, false]);

      h.mqtt.emitStateJson(stateJson(relays: <int, bool>{1: false}));
      await pumpEventQueue();
      expect(h.state.commandPipeline.hasPending, isFalse);
      expect(ep(h.state, 1).currentState, isFalse);
    });

    test('olmayan uç nokta / geçersiz numara: ağa çıkılmaz, başarısız olay', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.state.commandFailures.listen(failures.add);
      expect(await h.state.setRelay(99, true), isFalse);
      expect(await h.state.setRelay(0, true), isFalse);
      await pumpEventQueue();
      expect(failures, hasLength(2));
      expect(h.cloud.sentCommands, isEmpty);
    });

    test('triggerImpulse: iletim yeterli, iyimser değer yok', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      expect(await h.state.triggerImpulse(6), isTrue);
      expect(h.cloud.sentCommands.single['relay'], 6);
      expect(h.state.commandPipeline.hasPending, isFalse);
    });

    test('toplu komutlar: eski adlar kanonik cmd\'ye eşlenir', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      for (final entry in <String, String>{
        'lightsoff': 'all_lights_off',
        'shuttersup': 'all_shutters_up',
        'shuttersdown': 'all_shutters_down',
        'shuttersstop': 'all_shutters_stop',
        'all_off': 'all_lights_off',
      }.entries) {
        h.cloud.sentCommands.clear();
        expect(await h.state.cmdAll(entry.key), isTrue, reason: entry.key);
        expect(h.cloud.sentCommands.single['cmd'], entry.value);
      }
      h.state.commandFailures.listen(failures.add);
      expect(await h.state.cmdAll('patlat'), isFalse);
      await pumpEventQueue();
      expect(failures.single.reason, CommandFailureReason.validation);
    });
  });

  group('bulut: panjur (1 tabanlı pair, tip + kanal eşleştirme)', () {
    test('birleşik panjur listesi: iki satırlı panjur TEK kart (hayalet yok), 1 tabanlı pair', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      expect(h.state.shutterItems, hasLength(1));
      final s = h.state.shutterItems.single;
      expect(s.pair, 2);
      expect(s.name, 'Salon Panjur');
      expect(s.pos, 30);
      expect(s.upRelay, 3);
      expect(s.downRelay, 4);
      expect(h.state.relayItems.map((r) => r.id), <int>[1, 2, 5, 6]);
      expect(h.state.relayItems.every((r) => r.id != 3 && r.id != 4), isTrue, reason: 'panjur röleleri lamba kartı olmaz');
      expect(h.state.getShutterPosition(2), 30);
      expect(h.state.getShutterPosition(1), 0, reason: 'olmayan panjur');
    });

    test('state eşleştirme: panjur rölesi lamba satırını, lamba rölesi panjur satırını DEĞİŞTİRMEZ', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.mqtt.emitStateJson(stateJson(
        relays: <int, bool>{3: true, 4: true, 5: true, 1: true},
        shutters: <Map<String, dynamic>>[
          <String, dynamic>{'pair': 2, 'pos': 80, 'moving': true, 'dir': 1, 'target': 100},
        ],
        childLock: true,
        ip: '192.168.1.30',
      ));
      await pumpEventQueue();

      expect(ep(h.state, 1).currentState, isTrue);
      expect(ep(h.state, 5).currentState, isTrue);
      expect(ep(h.state, 2).currentState, isFalse);
      // panjur satırları: yalnızca konum güncellenir (röle durumu satırın currentState'ine yazılmaz)
      expect(ep(h.state, 3, shutter: true).currentState, isFalse);
      expect(ep(h.state, 4, shutter: true).currentState, isFalse);
      expect(ep(h.state, 3, shutter: true).shutterPosition, 80);
      expect(ep(h.state, 4, shutter: true).shutterPosition, 80);
      // hareket bilgisi
      final item = h.state.shutterItems.single;
      expect(item.pos, 80);
      expect(item.isMoving, isTrue);
      expect(item.direction, 1);
      expect(item.target, 100);
      expect(h.state.childLock, isTrue);
      expect(h.state.lastKnownDeviceIp, '192.168.1.30');
    });

    test('başka cihazın (uid) state iletisi bu cihazın satırlarını değiştirmez', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.mqtt.emitStateJson(stateJson(uid: 'AHBU-S3-BASKA99', relays: <int, bool>{1: true}));
      await pumpEventQueue();
      expect(ep(h.state, 1).currentState, isFalse);
    });

    test('setShutterPosition: iyimser konum, REST gövdesi, hedefi doğrulayan state onayı', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.state.commandFailures.listen(failures.add);

      final done = h.state.setShutterPosition(2, 60);
      expect(h.state.getShutterPosition(2), 60);
      expect(h.state.shutterItems.single.pos, 60);
      expect(await done, isTrue);
      final cmd = h.cloud.sentCommands.single;
      expect(cmd['shutter'], 2);
      expect(cmd['pos'], 60);
      expect(h.cloud.calls, contains('sendCommand:AHBU-S3-TEST01'));

      h.mqtt.emitStateJson(stateJson(shutters: <Map<String, dynamic>>[
        <String, dynamic>{'pair': 2, 'pos': 31, 'moving': true, 'dir': 1, 'target': 60},
      ]));
      await pumpEventQueue();
      expect(h.state.commandPipeline.hasPending, isFalse);
      expect(h.state.getShutterPosition(2), 31, reason: 'gerçek konum görünür');
      await h.clock.elapse(const Duration(seconds: 5));
      expect(failures, isEmpty);
    });

    test('onay yoksa konum GERÇEK konuma döner (eski kod eski konumu 0 sanıyordu)', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.state.commandFailures.listen(failures.add);
      await h.state.setShutterPosition(2, 90);
      expect(h.state.getShutterPosition(2), 90);
      await h.clock.elapse(const Duration(milliseconds: 2600));
      expect(h.state.getShutterPosition(2), 30, reason: 'oldPos = gerçek konum (30)');
      expect(failures.single.reason, CommandFailureReason.timeout);
    });

    test('geçersiz konum KIRPILMAZ, reddedilir; olmayan panjur ağa çıkmaz', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.state.commandFailures.listen(failures.add);
      expect(await h.state.setShutterPosition(2, 101), isFalse);
      expect(await h.state.setShutterPosition(2, -1), isFalse);
      expect(await h.state.setShutterPosition(0, 50), isFalse);
      expect(await h.state.setShutterPosition(1, 50), isFalse); // 1. panjur yok
      await pumpEventQueue();
      expect(failures, hasLength(4));
      expect(h.cloud.sentCommands, isEmpty);
      expect(h.state.getShutterPosition(2), 30);
    });

    test('cmdShutter up/down/stop: pair 1 tabanlı, cmd gövdesi, hareket iyimser, state ile onay', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      await h.state.cmdShutter(2, 'up');
      expect(h.cloud.sentCommands.single['shutter'], 2);
      expect(h.cloud.sentCommands.single['cmd'], 'up');
      expect(h.state.shutterItems.single.isMoving, isTrue);
      expect(h.state.shutterItems.single.direction, 1);

      h.mqtt.emitStateJson(stateJson(shutters: <Map<String, dynamic>>[
        <String, dynamic>{'pair': 2, 'pos': 35, 'moving': true, 'dir': 1, 'target': 255},
      ]));
      await pumpEventQueue();
      expect(h.state.commandPipeline.hasPending, isFalse);

      h.cloud.sentCommands.clear();
      await h.state.cmdShutter(2, 'stop');
      expect(h.cloud.sentCommands.single['cmd'], 'stop');
      expect(h.state.shutterItems.single.isMoving, isFalse);
      await h.state.cmdShutter(2, 'down');
      expect(h.cloud.sentCommands.last['cmd'], 'down');
      expect(h.state.commandPipeline.pending, hasLength(1), reason: 'panjur başına tek bekleyen komut');
    });

    test('cmdShutter: pos + percent konum komutuna yönlenir; geçersiz eylem reddedilir', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.state.commandFailures.listen(failures.add);
      await h.state.cmdShutter(2, 'pos', percent: 70);
      expect(h.cloud.sentCommands.single['pos'], 70);
      expect(await h.state.cmdShutter(2, 'sallan'), isFalse);
      expect(await h.state.cmdShutter(2, 'pos'), isFalse);
      await pumpEventQueue();
      expect(failures, hasLength(2));
    });
  });

  group('bulut: çocuk kilidi', () {
    test('iyimser, REST + cihaz state onayı; durum cihazdan gelir', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      expect(await h.state.toggleChildLock(true), isTrue);
      expect(h.state.childLock, isTrue);
      expect(h.cloud.calls, contains('setChildLock:true'));
      h.mqtt.emitStateJson(stateJson(childLock: true));
      await pumpEventQueue();
      expect(h.state.commandPipeline.hasPending, isFalse);
      expect(h.state.childLock, isTrue);
    });

    test('hata -> GERİ ALMA + sonuç denetimi (eskiden değer true kalıyordu)', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.state.commandFailures.listen(failures.add);
      h.cloud.setChildLockError = ApiException.network();
      expect(h.state.childLock, isFalse);
      expect(await h.state.toggleChildLock(true), isFalse);
      await pumpEventQueue();
      expect(h.state.childLock, isFalse);
      expect(failures.single.reason, CommandFailureReason.network);
    });

    test('onay gelmezse zaman aşımıyla eski değere döner', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      await h.state.toggleChildLock(true);
      expect(h.state.childLock, isTrue);
      await h.clock.elapse(const Duration(milliseconds: 2600));
      expect(h.state.childLock, isFalse);
    });
  });

  group('bulut: MQTT kopukken (settle) davranışı', () {
    test('canlı kanal yokken iyimser değer onay penceresi boyunca tutulur; HATA gösterilmez; REST ile uzlaşılır', () async {
      final h = await readyHarness(brokerConnected: false);
      addTearDown(h.dispose);
      h.state.commandFailures.listen(failures.add);
      expect(h.state.brokerConnected, isFalse);
      final before = h.cloud.count('fetchEndpoints');

      // sunucu DB'si komuttan sonra yeni değeri döndürecek
      h.cloud.endpoints[kHomeA] = testEndpoints().map((e) => e.channel == 1 ? e.copyWith(currentState: true) : e).toList();
      expect(await h.state.setRelay(1, true), isTrue);
      expect(ep(h.state, 1).currentState, isTrue);
      await h.clock.elapse(const Duration(milliseconds: 1500));
      expect(h.cloud.count('fetchEndpoints'), greaterThan(before), reason: 'REST ile gerçek durum yeniden okundu');
      expect(h.state.commandPipeline.hasPending, isFalse, reason: 'REST anlık görüntüsü hedefi doğruladı');
      expect(ep(h.state, 1).currentState, isTrue);
      await h.clock.elapse(const Duration(seconds: 5));
      expect(failures, isEmpty);
    });
  });

  group('durum alımı: canlı/saklı ileti, çevrimiçi bilgisi', () {
    test('saklı (retained) state çevrimiçiliği KANITLAMAZ; canlı state çevrimiçi yapar; status ayrı alan', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.state.setPresenceForTesting(DevicePresence.unknown);
      h.mqtt.emitStateJson(stateJson(relays: <int, bool>{1: true}), retained: true);
      await pumpEventQueue();
      expect(ep(h.state, 1).currentState, isTrue, reason: 'son bilinen değer yine gösterilir');
      expect(h.state.devicePresence, DevicePresence.unknown);

      h.mqtt.emitPresence(false, retained: true);
      await pumpEventQueue();
      expect(h.state.devicePresence, DevicePresence.offline);
      expect(h.state.connState, ConnectionStateEnum.offline);

      h.mqtt.emitStateJson(stateJson(relays: <int, bool>{1: false}));
      await pumpEventQueue();
      expect(h.state.devicePresence, DevicePresence.online);
      expect(h.state.isConnected, isTrue);
    });

    test('broker durumu canlı akıştan izlenir (cihaz durumundan bağımsız)', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      expect(h.state.mqttLinkState, MqttLinkState.connected);
      h.mqtt.setLink(MqttLinkState.reconnecting);
      await pumpEventQueue();
      expect(h.state.brokerConnected, isFalse);
      expect(h.state.mqttLinkState, MqttLinkState.reconnecting);
      expect(h.state.deviceOnline, isTrue, reason: 'cihaz bilgisi korunur');
      h.mqtt.setLink(MqttLinkState.connected);
      await pumpEventQueue();
      expect(h.state.brokerConnected, isTrue);
    });

    test('MQTT kimliği sunucudan istenir (gömülü parola yok) ve kurulum kimliği iletilir', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      expect(h.cloud.calls, contains('mqttCredentials:$kHomeA'));
      expect(h.mqtt.startCount, 1);
      expect(h.mqtt.lastCredentials!.username, 'a_h_test_1');
    });
  });

  group('yetki kapıları (savunmacı denetim)', () {
    test('misafir: durum görür ve komut verir; toplu komut / çocuk kilidi / kural / davet / PIN yok', () async {
      final guestHome = HomeModel(
        id: kHomeA,
        name: 'Misafir Evi',
        role: 'guest',
        mqttTopicId: 'h_test',
        guestValidFrom: kTestNow.subtract(const Duration(hours: 1)),
        guestValidUntil: kTestNow.add(const Duration(hours: 5)),
      );
      final h = await readyHarness(home: guestHome);
      addTearDown(h.dispose);
      h.state.commandFailures.listen(failures.add);
      final caps = h.state.capabilities;
      expect(caps.isGuest, isTrue);
      expect(caps.canControlDevices, isTrue);

      expect(await h.state.setRelay(1, true), isTrue);
      h.cloud.sentCommands.clear();
      expect(await h.state.cmdAll('lightsoff'), isFalse);
      expect(await h.state.toggleChildLock(true), isFalse);
      await pumpEventQueue();
      expect(failures.map((f) => f.reason), everyElement(CommandFailureReason.forbidden));
      expect(h.cloud.sentCommands, isEmpty);

      await expectLater(h.state.generateServicePin(), throwsA(isA<ApiException>().having((e) => e.isForbidden, 'forbidden', true)));
      await expectLater(h.state.createScheduledRule(channel: 1, channelType: 'relay', action: 'on', hour: 8, minute: 0, daysOfWeek: <int>[1]), throwsA(isA<ApiException>()));
      await expectLater(h.state.createHomeInvitation(), throwsA(isA<ApiException>()));
      await expectLater(h.state.removeHomeMember('x'), throwsA(isA<ApiException>()));
      await expectLater(h.state.initiateHomeTransfer(targetIdentifier: 'a@b.c'), throwsA(isA<ApiException>()));
      await expectLater(h.state.updateEndpoint(endpointId: 'e1', name: 'x'), throwsA(isA<ApiException>()));
      expect(await h.state.setMode(AppMode.direct), isFalse, reason: 'misafir mod anahtarını kullanamaz');
      expect(h.state.mode, AppMode.cloud);
    });

    test('süresi dolmuş misafir komut veremez', () async {
      final expired = HomeModel(
        id: kHomeA,
        name: 'Eski Misafir',
        role: 'guest',
        mqttTopicId: 'h_test',
        guestValidUntil: kTestNow.subtract(const Duration(hours: 1)),
      );
      final h = await readyHarness(home: expired);
      addTearDown(h.dispose);
      h.state.commandFailures.listen(failures.add);
      expect(h.state.isGuestExpired, isTrue);
      expect(h.state.capabilities.canControlDevices, isFalse);
      expect(await h.state.setRelay(1, true), isFalse);
      await pumpEventQueue();
      expect(failures.single.reason, CommandFailureReason.forbidden);
      expect(h.cloud.sentCommands, isEmpty);
      expect(h.cloud.count('fetchEndpoints'), 0, reason: 'süresi dolmuş misafir için veri çekilmez');
      expect(h.mqtt.startCount, 0, reason: 've MQTT başlatılmaz');
    });

    test('sakin: komut + çocuk kilidi var; kalibrasyon / davet / devir / servis PIN yok', () async {
      final h = await readyHarness(role: 'resident');
      addTearDown(h.dispose);
      expect(await h.state.cmdAll('lightsoff'), isTrue);
      expect(await h.state.toggleChildLock(true), isTrue);
      await expectLater(h.state.updateEndpoint(endpointId: 'e1', shutterDurationSec: 20), throwsA(isA<ApiException>()));
      await expectLater(h.state.createHomeInvitation(), throwsA(isA<ApiException>()));
      await expectLater(h.state.generateServicePin(), throwsA(isA<ApiException>()));
      await expectLater(h.state.emergencyResetDevice(deviceUuid: 'AHBU-S3-ABC123', confirmUid: 'AHBU-S3-ABC123', reason: 'x' * 20), throwsA(isA<ApiException>()));
    });

    test('rol ev bazlıdır: küresel `user` ev sahibi olabilir (isOwner), küresel rol owner OLAMAZ', () async {
      final h = await readyHarness(role: 'owner');
      addTearDown(h.dispose);
      expect(h.state.currentUser!.role, 'user');
      expect(h.state.isOwner, isTrue);
      expect(h.state.capabilities.canInvite, isTrue);
      expect(h.state.capabilities.canCommission, isFalse);
      expect(h.state.isSuperUser, isFalse);
    });

    test('bilinmeyen ev rolü = hiçbir yetki', () async {
      final h = await readyHarness(role: 'admin');
      addTearDown(h.dispose);
      expect(h.state.capabilities.hasHomeAccess, isFalse);
      expect(await h.state.setRelay(1, true), isFalse);
      expect(h.state.capabilities.canControlDevices, isFalse);
    });
  });

  group('ev değişimi', () {
    test('selectHome ev kapsamlı TÜM önbellekleri sıfırlar; bekleyen komutlar iptal; MQTT yeniden başlar', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.cloud.homes = <HomeModel>[testHome(), testHome(id: kHomeB, name: 'Ev B', topic: 'h_b')];
      h.cloud.endpoints[kHomeB] = <EndpointModel>[
        EndpointModel(id: 'b1', homeId: kHomeB, deviceUuid: 'AHBU-S3-OTHER01', channel: 1, name: 'B Lamba', room: 'Genel', endpointType: 'light', currentState: true),
      ];
      h.cloud.devicesByHome[kHomeB] = <DeviceInfo>[];
      await h.state.fetchHomes(autoSelect: false);

      // A evinde durum biriktir
      h.mqtt.emitStateJson(stateJson(
        relays: <int, bool>{1: true},
        shutters: <Map<String, dynamic>>[<String, dynamic>{'pair': 2, 'pos': 50, 'moving': true, 'dir': 1}],
        childLock: true,
        ip: '10.0.0.5',
      ));
      await pumpEventQueue();
      await h.state.toggleRelay(2);
      expect(h.state.commandPipeline.hasPending, isTrue);
      expect(h.state.childLock, isTrue);
      expect(h.state.lastKnownDeviceIp, '10.0.0.5');
      final stopsBefore = h.mqtt.stopCount;
      final startsBefore = h.mqtt.startCount;

      await h.state.selectHome(h.state.homeById(kHomeB)!);

      expect(h.state.activeHome!.id, kHomeB);
      expect(h.state.commandPipeline.hasPending, isFalse, reason: 'bekleyen komutlar iptal');
      expect(h.state.cloudEndpoints.map((e) => e.id), <String>['b1'], reason: 'A evinin uç noktaları kalmadı');
      expect(h.state.shutterItems, isEmpty);
      expect(h.state.childLock, isFalse);
      expect(h.state.lastKnownDeviceIp, isNull);
      expect(h.state.devices, isEmpty);
      expect(h.state.servicePin, isNull);
      expect(h.state.scheduledRules, isEmpty);
      expect(h.mqtt.stopCount, greaterThan(stopsBefore));
      expect(h.mqtt.startCount, startsBefore + 1);
      await h.clock.elapse(const Duration(seconds: 10));
      expect(failures, isEmpty, reason: 'iptal edilen komut geri alma bildirimi üretmez');
    });

    test('eski evin geç gelen yanıtı yeni evin verisini ezmez (ev nesli)', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.cloud.homes = <HomeModel>[testHome(), testHome(id: kHomeB, name: 'Ev B', topic: 'h_b')];
      h.cloud.endpoints[kHomeB] = <EndpointModel>[
        EndpointModel(id: 'b1', homeId: kHomeB, channel: 1, name: 'B', room: 'Genel', endpointType: 'light', currentState: false),
      ];
      await h.state.fetchHomes(autoSelect: false);
      await h.state.selectHome(h.state.homeById(kHomeB)!);
      // A evinin eski bir state iletisi (MQTT durmuş olsa bile) B'ye uygulanmamalı
      h.mqtt.emitStateJson(stateJson(relays: <int, bool>{1: true}));
      await pumpEventQueue();
      expect(h.state.cloudEndpoints.single.id, 'b1');
    });
  });

  group('doğrudan (LAN) mod', () {
    Map<String, dynamic> statusBody({bool r3 = false, int pos = 20, bool moving = false, int dir = 0, int? target, bool childLock = false}) =>
        <String, dynamic>{
          'device_name': 'Pano',
          'ip': '192.168.1.30',
          'wifi_connected': true,
          'child_lock': childLock,
          'relays': <Map<String, dynamic>>[
            <String, dynamic>{'id': 1, 'name': 'Avize', 'type': 1, 'state': false},
            <String, dynamic>{'id': 2, 'name': 'Avize Aşağı', 'type': 2, 'state': false},
            <String, dynamic>{'id': 3, 'name': 'Mutfak', 'type': 0, 'state': r3},
            <String, dynamic>{'id': 4, 'name': 'Spot', 'type': 0, 'state': false},
          ],
          'shutters': <Map<String, dynamic>>[
            <String, dynamic>{'pair': 1, 'pos': pos, 'is_moving': moving, 'dir': dir, 'target': target ?? 255},
            <String, dynamic>{'pair': 2, 'pos': 0, 'is_moving': false, 'dir': 0, 'target': 255}, // hayalet: 3-4 lamba
          ],
          'dis': <Map<String, dynamic>>[],
        };

    Future<StateHarness> directHarness({int pos = 20}) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final h = StateHarness();
      h.state.setCurrentUserForTesting(const UserModel(id: 'u', email: 'a@b.c', fullName: 'A', role: 'user'));
      h.state.setAuthStatusForTesting(AuthStatus.authenticated);
      h.state.setHomesForTesting(<HomeModel>[testHome()]);
      h.directMock.on('GET', '/api/status', (r) => jsonResponse(statusBody(pos: pos)));
      await h.state.setMode(AppMode.direct);
      await h.state.setHost('192.168.1.30');
      h.direct.localKey = 'devicekey-1234';
      await h.state.refresh();
      return h;
    }

    test('durum çözülür: hayalet panjur süzülür; her istekte X-Device-Key gider', () async {
      final h = await directHarness();
      addTearDown(h.dispose);
      expect(h.state.mode, AppMode.direct);
      expect(h.state.connState, ConnectionStateEnum.connected);
      expect(h.state.isConnected, isTrue);
      expect(h.state.status!.shutters.map((s) => s.pair), <int>[1], reason: 'pair 2 hayalet (rölelerin ikisi de lamba)');
      expect(h.state.shutterItems.single.name, 'Avize');
      expect(h.state.relayItems.map((r) => r.id), <int>[3, 4]);
      final statusRequests = h.directMock.where('GET', '/api/status');
      expect(statusRequests, isNotEmpty);
      expect(statusRequests.last.headers['X-Device-Key'], 'devicekey-1234');
    });

    test('röle: state=1/0 ile açık komut, anahtar başlığı, iyimser + poll ile onay', () async {
      final h = await directHarness();
      addTearDown(h.dispose);
      h.directMock.on('POST', '/api/relay', (r) => jsonResponse(<String, dynamic>{'status': 'ok'}));
      var statusCalls = 0;
      h.directMock.on('GET', '/api/status', (r) {
        statusCalls++;
        return jsonResponse(statusBody(r3: statusCalls >= 1)); // komuttan sonraki ilk yoklamada cihaz açık raporlar
      });
      final result = h.state.toggleRelay(3);
      expect(h.state.status!.relayById(3)!.state, isTrue, reason: 'iyimser');
      expect(await result, isTrue);
      final post = h.directMock.where('POST', '/api/relay').single;
      expect(post.url.queryParameters, <String, String>{'ch': '3', 'state': '1'});
      expect(post.headers['X-Device-Key'], 'devicekey-1234');
      await h.clock.elapse(const Duration(milliseconds: 400)); // hızlı yoklama
      expect(h.state.commandPipeline.hasPending, isFalse, reason: 'poll hedefi doğruladı');
      expect(h.state.status!.relayById(3)!.state, isTrue);
    });

    test('panjur konumu: pair 1 tabanlı ve pos için val ZORUNLU', () async {
      final h = await directHarness();
      addTearDown(h.dispose);
      h.directMock.on('POST', '/api/relay', (r) => jsonResponse(<String, dynamic>{'status': 'ok'}));
      await h.state.setShutterPosition(1, 65);
      final post = h.directMock.where('POST', '/api/relay').single;
      expect(post.url.queryParameters, <String, String>{'pair': '1', 'cmd': 'pos', 'val': '65'});
      expect(h.state.getShutterPosition(1), 65);
      h.directMock.requests.clear();
      await h.state.cmdShutter(1, 'up');
      expect(h.directMock.where('POST', '/api/relay').single.url.queryParameters, <String, String>{'pair': '1', 'cmd': 'up'});
    });

    test('komut LAN hatasıyla düşerse anında geri alma', () async {
      final h = await directHarness();
      addTearDown(h.dispose);
      h.state.commandFailures.listen(failures.add);
      h.directMock.on('POST', '/api/relay', (r) => jsonResponse(<String, dynamic>{'error': 'unauthorized'}, status: 401));
      expect(await h.state.toggleRelay(3), isFalse);
      await pumpEventQueue();
      expect(h.state.status!.relayById(3)!.state, isFalse);
      expect(failures.single.reason, CommandFailureReason.forbidden);
    });

    test('ardışık 3 yoklama hatası -> çevrimdışı; tek hata çevrimdışı yapmaz; başarı sayacı sıfırlar', () async {
      final h = await directHarness();
      addTearDown(h.dispose);
      expect(h.state.connState, ConnectionStateEnum.connected);
      var fail = true;
      h.directMock.on('GET', '/api/status', (r) {
        if (fail) throw const FormatException('ağ yok');
        return jsonResponse(statusBody());
      });
      // arka plan yoklaması (periyodik zamanlayıcı) sessiz hata sayar
      await h.clock.elapse(const Duration(milliseconds: 1600)); // 1. hata
      expect(h.state.connState, ConnectionStateEnum.connected, reason: 'tek hata çevrimdışı yapmaz');
      await h.clock.elapse(const Duration(milliseconds: 1500)); // 2. hata
      expect(h.state.connState, ConnectionStateEnum.connected);
      await h.clock.elapse(const Duration(milliseconds: 1500)); // 3. hata
      expect(h.state.connState, ConnectionStateEnum.offline);
      expect(h.state.isConnected, isFalse);

      fail = false; // cihaz geri geldi: başarı sayacı sıfırlar
      await h.clock.elapse(const Duration(milliseconds: 1600));
      expect(h.state.connState, ConnectionStateEnum.connected);
      fail = true;
      await h.clock.elapse(const Duration(milliseconds: 1600)); // sayaç sıfırdan: 1. hata
      expect(h.state.connState, ConnectionStateEnum.connected);
    });

    test('kullanıcı tetiklemeli yenileme (çekip bırak) ilk hatada çevrimdışı gösterir', () async {
      final h = await directHarness();
      addTearDown(h.dispose);
      h.directMock.on('GET', '/api/status', (r) => throw const FormatException('ağ yok'));
      await h.state.refresh(); // silent: false
      expect(h.state.connState, ConnectionStateEnum.offline);
    });

    test('yoklama TEK-UÇUŞLU: yavaş cihazda istekler üst üste binmez', () async {
      final h = await directHarness();
      addTearDown(h.dispose);
      final gate = Completer<void>();
      var inFlight = 0;
      var maxInFlight = 0;
      var total = 0;
      h.directMock.on('GET', '/api/status', (r) async {
        total++;
        inFlight++;
        if (inFlight > maxInFlight) maxInFlight = inFlight;
        await gate.future;
        inFlight--;
        return jsonResponse(statusBody());
      });
      await h.state.setMode(AppMode.cloud);
      final modeFuture = h.state.setMode(AppMode.direct);
      await h.clock.elapse(const Duration(seconds: 10)); // 6 poll aralığı geçti
      expect(maxInFlight, 1);
      expect(total, 1, reason: 'ilk istek dönmeden yenisi başlatılmaz');
      gate.complete();
      await modeFuture;
      await h.clock.elapse(const Duration(milliseconds: 1600));
      expect(maxInFlight, 1);
    });

    test('anahtar reddi (401): çevrimdışı sayılmaz, hata görünür', () async {
      final h = await directHarness();
      addTearDown(h.dispose);
      h.directMock.on('GET', '/api/status', (r) => jsonResponse(<String, dynamic>{'error': 'unauthorized'}, status: 401));
      await h.state.refresh();
      expect(h.state.directError, contains('anahtar'));
      expect(h.state.connState, isNot(ConnectionStateEnum.offline));
    });

    test('adres ayarlı değilse ağa çıkılmaz', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final h = StateHarness();
      addTearDown(h.dispose);
      h.state.setModeForTesting(AppMode.direct);
      await h.state.refresh();
      expect(h.directMock.requests, isEmpty);
      expect(h.state.connState, ConnectionStateEnum.offline);
      expect(h.state.directError, isNotNull);
    });

    test('doğrudan modda yetki: anahtarsız oturumsuz kullanıcı yalnızca durum görür', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final h = StateHarness();
      addTearDown(h.dispose);
      h.state.setModeForTesting(AppMode.direct);
      expect(h.state.capabilities, const Capabilities.none());
      h.direct.localKey = 'devicekey-1234';
      expect(h.state.capabilities.canControlDevices, isTrue, reason: 'oturumsuz yerel mod + anahtar: yalnızca komut');
      expect(h.state.capabilities.canInvite, isFalse);
    });
  });
}
