import 'dart:async';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/services/ev_mqtt_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/support.dart';

/// Çocuk kilidi (D10): gerçek `AutomationState` + `CommandPipeline` + sahte bulut/MQTT/LAN ile
/// DAVRANIŞ testleri. (Eski testler yalnızca iyimser bool'u doğruluyordu; bunlar iletim,
/// onay, geri alma, bayat yanıt, bilinmeyen durum ve LAN yollarını doğrular.)
void main() {
  late List<CommandFailure> failures;
  setUp(() => failures = <CommandFailure>[]);

  /// Cihazın kilit durumunu bildirmesi (MQTT `state.child_lock`).
  Future<void> deviceReports(StateHarness h, bool locked, {String uid = 'AHBU-S3-TEST01', bool retained = false}) async {
    h.mqtt.emitStateJson(stateJson(uid: uid, childLock: locked), retained: retained);
    await pumpEventQueue();
  }

  group('bulut: iletim, onay, geri alma', () {
    test('aç: iyimser "kilitli", iletim = "uygulanıyor" (pending), cihaz state onayıyla tamam', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      await deviceReports(h, false);
      expect(h.state.childLockStatus, ChildLockStatus.unlocked);
      expect(h.state.childLockPending, isFalse);

      final dispatch = await h.state.setChildLock(true);
      expect(dispatch.ok, isTrue);
      expect(h.cloud.calls, contains('setChildLock:true'));
      // REST delivered:true "uygulandı" DEĞİL: hâlâ bekliyor.
      expect(h.state.childLockPending, isTrue);
      expect(h.state.childLockStatus, ChildLockStatus.locked, reason: 'iyimser hedef görünür');

      await deviceReports(h, true);
      expect(h.state.childLockPending, isFalse);
      expect(h.state.childLockStatus, ChildLockStatus.locked);
      expect(h.state.childLockUpdatedAt, isNotNull);
      h.state.commandFailures.listen(failures.add);
      await h.clock.elapse(const Duration(seconds: 10));
      expect(failures, isEmpty);
      expect(h.state.childLockStatus, ChildLockStatus.locked);
    });

    test('kapat: bilinçli komut aynı yoldan; cihaz onaylayana kadar "uygulanıyor"', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      await deviceReports(h, true);
      await h.state.setChildLock(false);
      expect(h.state.childLockStatus, ChildLockStatus.unlocked);
      expect(h.state.childLockPending, isTrue);
      await deviceReports(h, false);
      expect(h.state.childLockPending, isFalse);
      expect(h.state.childLockStatus, ChildLockStatus.unlocked);
    });

    for (final scenario in <(String, Future<CommandResult> Function(String, bool)?, Object?, CommandFailureReason)>[
      ('delivered=false', (home, on) async => const CommandResult(delivered: false, deviceOnline: true), null, CommandFailureReason.notDelivered),
      ('device_online=false', (home, on) async => const CommandResult(delivered: true, deviceOnline: false), null, CommandFailureReason.offline),
      (
        '409 DEVICE_OFFLINE',
        null,
        const ApiException(statusCode: 409, code: 'DEVICE_OFFLINE', message: 'Pano çevrimdışı'),
        CommandFailureReason.offline
      ),
      (
        '403 FORBIDDEN',
        null,
        const ApiException(statusCode: 403, code: 'FORBIDDEN', message: 'Yetkiniz yok'),
        CommandFailureReason.forbidden
      ),
      (
        '502 BROKER_UNAVAILABLE',
        null,
        const ApiException(statusCode: 502, code: 'BROKER_UNAVAILABLE', message: 'x'),
        CommandFailureReason.brokerUnavailable
      ),
      ('ağ hatası', null, ApiException.network(), CommandFailureReason.network),
    ]) {
      test('${scenario.$1} -> ANINDA geri alma + tipli hata; görünür değer eski kalır', () async {
        final h = await readyHarness();
        addTearDown(h.dispose);
        h.state.commandFailures.listen(failures.add);
        await deviceReports(h, false);
        h.cloud.setChildLockHandler = scenario.$2;
        h.cloud.setChildLockError = scenario.$3;

        final dispatch = await h.state.setChildLock(true);
        await pumpEventQueue();
        expect(dispatch.ok, isFalse);
        expect(dispatch.failure!.reason, scenario.$4);
        expect(h.state.childLockPending, isFalse);
        expect(h.state.childLockStatus, ChildLockStatus.unlocked, reason: 'eski (gerçek) değer');
        expect(failures.single.reason, scenario.$4);
        expect(failures.single.message, isNotEmpty);
        await h.clock.elapse(const Duration(seconds: 10));
        expect(failures, hasLength(1), reason: 'zamanlayıcı ikinci bir hata üretmemeli');
      });
    }

    test('çevrimdışı cihaz: rollback + cihaz "çevrimdışı" olarak işaretlenir + "son bilinen" (stale)', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      await deviceReports(h, true);
      expect(h.state.childLockStale, isFalse);
      h.cloud.setChildLockError =
          const ApiException(statusCode: 409, code: 'DEVICE_OFFLINE', message: 'Pano çevrimdışı');
      await h.state.setChildLock(false);
      await pumpEventQueue();
      expect(h.state.childLockStatus, ChildLockStatus.locked);
      expect(h.state.devicePresence, DevicePresence.offline);
      expect(h.state.childLockStale, isTrue);
    });

    test('iletildi ama 2.5 sn içinde doğrulanmazsa: görünür değer GERİ ALINIR + nötr mesaj + yeniden eşitleme', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.state.commandFailures.listen(failures.add);
      await deviceReports(h, false);
      final getsBefore = h.cloud.count('getChildLock');
      final endpointsBefore = h.cloud.count('fetchEndpoints');

      await h.state.setChildLock(true);
      expect(h.state.childLockStatus, ChildLockStatus.locked);
      await h.clock.elapse(const Duration(milliseconds: 2400));
      expect(h.state.childLockStatus, ChildLockStatus.locked, reason: '2.4 sn: pencere açık');
      await h.clock.elapse(const Duration(milliseconds: 300));
      expect(h.state.childLockPending, isFalse);
      expect(h.state.childLockStatus, ChildLockStatus.unlocked, reason: 'görünür değer geri alındı (eski kodda kilitli kalıyordu)');
      expect(failures.single.reason, CommandFailureReason.timeout);
      expect(failures.single.message, contains('onay'));
      // komut uygulanmış olabilir: durum hemen yeniden okunur
      expect(h.cloud.count('getChildLock'), greaterThan(getsBefore));
      expect(h.cloud.count('fetchEndpoints'), greaterThan(endpointsBefore));
    });

    test('REST 2.0 sn sürüp state 2.7 sn sonra gelirse YANLIŞ zaman aşımı yok (pencere iletimden başlar)', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.state.commandFailures.listen(failures.add);
      await deviceReports(h, false);
      final gate = Completer<void>();
      h.cloud.setChildLockHandler = (home, on) async {
        await gate.future;
        return const CommandResult(delivered: true, deviceOnline: true, commandId: 'c1');
      };
      final future = h.state.setChildLock(true);
      await h.clock.elapse(const Duration(milliseconds: 2000));
      expect(failures, isEmpty);
      expect(h.state.childLockPending, isTrue);
      gate.complete();
      expect((await future).ok, isTrue);
      await h.clock.elapse(const Duration(milliseconds: 700)); // t = 2.7 sn
      expect(h.state.childLockPending, isTrue);
      await deviceReports(h, true);
      expect(h.state.childLockPending, isFalse);
      expect(h.state.childLockStatus, ChildLockStatus.locked);
      await h.clock.elapse(const Duration(seconds: 10));
      expect(failures, isEmpty);
    });

    test('sunucu no_change (pano zaten hedefte): yeni state gelmese de anında doğrulanmış', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.state.commandFailures.listen(failures.add);
      h.cloud.setChildLockHandler =
          (home, on) async => const CommandResult(delivered: true, deviceOnline: true, noChange: true);
      final dispatch = await h.state.setChildLock(true);
      expect(dispatch.ok, isTrue);
      expect(h.state.childLockPending, isFalse);
      expect(h.state.childLockStatus, ChildLockStatus.locked);
      await h.clock.elapse(const Duration(seconds: 10));
      expect(failures, isEmpty);
      expect(h.state.childLockStatus, ChildLockStatus.locked);
    });

    test('çift dokunuş: tek bekleyen komut, son niyet görünür, ilk çağrı "superseded", yanlış hata yok', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.state.commandFailures.listen(failures.add);
      await deviceReports(h, false);
      final gate = Completer<void>();
      var n = 0;
      h.cloud.setChildLockHandler = (home, on) async {
        n++;
        if (n == 1) await gate.future;
        return CommandResult(delivered: true, deviceOnline: true, commandId: 'c$n');
      };
      final first = h.state.setChildLock(true);
      final second = h.state.setChildLock(false);
      expect(h.state.childLockStatus, ChildLockStatus.unlocked, reason: 'son niyet');
      expect(h.state.commandPipeline.pending, hasLength(1));
      expect(h.state.commandPipeline.pendingFor('childLock')!.original, ChildLockStatus.unlocked, reason: 'ilk dokunuştaki gerçek değer');
      gate.complete();
      expect((await first).status, CommandDispatchStatus.superseded);
      expect((await second).ok, isTrue);
      expect(h.cloud.calls.where((c) => c.startsWith('setChildLock')), <String>['setChildLock:true', 'setChildLock:false']);
      await deviceReports(h, false);
      expect(h.state.childLockPending, isFalse);
      expect(failures, isEmpty);
    });

    test('hızlı ardışık üç dokunuş: en çok iki istek (uçuştaki + son niyet), araya girenler atlanır', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      final gate = Completer<void>();
      var n = 0;
      h.cloud.setChildLockHandler = (home, on) async {
        n++;
        if (n == 1) await gate.future;
        return CommandResult(delivered: true, deviceOnline: true, commandId: 'c$n');
      };
      final a = h.state.setChildLock(true);
      final b = h.state.setChildLock(false);
      final c = h.state.setChildLock(true);
      gate.complete();
      await Future.wait<CommandDispatch>(<Future<CommandDispatch>>[a, b, c]);
      final sent = h.cloud.calls.where((x) => x.startsWith('setChildLock')).toList();
      expect(sent.length, lessThanOrEqualTo(2));
      expect(sent.last, 'setChildLock:true');
    });

    test('toggleChildLock bool\'u yalnızca "iletildi": çift dokunuşta ilk çağrı false döner (arayüz buna güvenmemeli)', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      final gate = Completer<void>();
      var n = 0;
      h.cloud.setChildLockHandler = (home, on) async {
        n++;
        if (n == 1) await gate.future;
        return CommandResult(delivered: true, deviceOnline: true, commandId: 'c$n');
      };
      final first = h.state.toggleChildLock(true);
      final second = h.state.toggleChildLock(false);
      gate.complete();
      expect(await first, isFalse);
      expect(await second, isTrue);
    });
  });

  group('bekleyen komut varken refresh/GET sonucu arayüzü EZMEZ', () {
    test('uçuştaki KİLİT AÇMA, eşzamanlı refresh() ile "doğrulanmış" sayılmaz; sonraki 409 yutulmaz', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.state.commandFailures.listen(failures.add);
      await deviceReports(h, true); // pano kilitli
      final gate = Completer<void>();
      h.cloud.setChildLockHandler = (home, on) async {
        await gate.future;
        throw const ApiException(statusCode: 409, code: 'DEVICE_OFFLINE', message: 'Pano çevrimdışı');
      };
      final unlock = h.state.setChildLock(false);
      expect(h.state.childLockStatus, ChildLockStatus.unlocked);

      await h.state.refresh(); // REST'ten türetilen anlık görüntü (child_lock BİLİNMİYOR) onay SAYILMAMALI
      expect(h.state.childLockPending, isTrue, reason: 'REST türevi anlık görüntü komutu doğrulayamaz');
      expect(h.state.childLockStatus, ChildLockStatus.unlocked);

      gate.complete();
      final result = await unlock;
      await pumpEventQueue();
      expect(result.ok, isFalse);
      expect(failures.single.reason, CommandFailureReason.offline);
      expect(h.state.childLockStatus, ChildLockStatus.locked, reason: 'pano gerçekte hâlâ kilitli');
    });

    test('bekleyen komut varken sunucudan gelen eski GET değeri görünen değeri değiştirmez', () async {
      final h = await readyHarness(brokerConnected: false); // canlı kanal yok: REST uygulanabilir olsun
      addTearDown(h.dispose);
      h.cloud.childLockValue = false;
      await h.state.refresh();
      expect(h.state.childLockStatus, ChildLockStatus.unlocked);
      final gate = Completer<void>();
      h.cloud.setChildLockHandler = (home, on) async {
        await gate.future;
        return const CommandResult(delivered: true, deviceOnline: true);
      };
      final f = h.state.setChildLock(true);
      expect(h.state.childLockStatus, ChildLockStatus.locked);
      await h.state.refresh(); // GET hâlâ false (sunucu gölgesi)
      expect(h.state.childLockStatus, ChildLockStatus.locked, reason: 'bekleyen hedef ezilmedi');
      expect(h.state.childLockPending, isTrue);
      gate.complete();
      await f;
    });

    test('bayat GET yanıtı daha yeni MQTT durumunu EZMEZ', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.cloud.childLockValue = false;
      h.cloud.childLockGate = Completer<void>();
      final refresh = h.state.refresh(silent: true); // GET uçuşta (değer: false)
      await pumpEventQueue();
      await deviceReports(h, true); // daha yeni cihaz bildirimi
      expect(h.state.childLockStatus, ChildLockStatus.locked);
      h.cloud.childLockGate!.complete();
      await refresh;
      await pumpEventQueue();
      expect(h.state.childLockStatus, ChildLockStatus.locked, reason: 'eski REST değeri uygulanmadı');
    });

    test('canlı kanal bağlıyken cihaz değeri biliniyorsa REST gölgesi (sunucu) görünen değeri değiştirmez', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      await deviceReports(h, false);
      h.cloud.childLockValue = true; // sunucu gölgesi yayın anında yazılmış ama cihaz uygulamadı
      await h.state.refresh();
      expect(h.state.childLockStatus, ChildLockStatus.unlocked, reason: 'cihaz bildirimi tek doğruluk kaynağı');
    });
  });

  group('bilinmeyen durum "kilit kapalı" GÖSTERİLMEZ (fail-open yok)', () {
    for (final error in <Object>[
      const ApiException(statusCode: 500, message: 'x'),
      const ApiException(statusCode: 401, message: 'x'),
      const ApiException(statusCode: 403, code: 'FORBIDDEN', message: 'x'),
    ]) {
      test('getChildLock hatası ($error) -> unknown', () async {
        final h = await readyHarness(configure: (h) => h.cloud.childLockError = error);
        addTearDown(h.dispose);
        expect(h.cloud.count('getChildLock'), 1);
        expect(h.state.childLockStatus, ChildLockStatus.unknown);
        expect(h.state.childLock, isFalse, reason: 'bool alanı bilinmeyeni false gösterir; arayüz childLockStatus kullanmalı');
        expect(h.state.childLockUpdatedAt, isNull);
        expect(h.state.childLockStale, isFalse);
      });
    }

    test('unknown -> cihaz bildirimiyle bilinir; ev değişiminde tekrar unknown', () async {
      final h = await readyHarness(configure: (h) => h.cloud.childLockError = ApiException.network());
      addTearDown(h.dispose);
      expect(h.state.childLockStatus, ChildLockStatus.unknown);
      await deviceReports(h, true);
      expect(h.state.childLockStatus, ChildLockStatus.locked);

      h.cloud.homes = <HomeModel>[testHome(), testHome(id: kHomeB, name: 'Ev B', topic: 'h_b')];
      h.cloud.endpoints[kHomeB] = <EndpointModel>[];
      await h.state.fetchHomes(autoSelect: false);
      h.cloud.childLockGate = Completer<void>(); // yeni evin REST yanıtını beklet
      final switching = h.state.selectHome(h.state.homeById(kHomeB)!);
      await pumpEventQueue();
      expect(h.state.childLockStatus, ChildLockStatus.unknown, reason: 'A evinin kilit durumu B\'ye taşınmaz');
      h.cloud.childLockGate!.complete();
      await switching;
    });

    test('REST başarılıysa (canlı kanal yokken) bilinen değer gösterilir', () async {
      final h = await readyHarness(brokerConnected: false, configure: (h) => h.cloud.childLockValue = true);
      addTearDown(h.dispose);
      expect(h.state.childLockStatus, ChildLockStatus.locked);
      expect(h.state.childLockUpdatedAt, isNotNull);
    });

    test('çevrimdışı panonun retained durumu "son bilinen" (stale) olarak işaretlenir', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.state.setPresenceForTesting(DevicePresence.offline);
      await deviceReports(h, true, retained: true);
      expect(h.state.childLockStatus, ChildLockStatus.locked);
      expect(h.state.childLockStale, isTrue);
      h.mqtt.emitPresence(true);
      await pumpEventQueue();
      expect(h.state.childLockStale, isFalse);
    });

    test('broker koptuysa cihazdan gelen değer "son bilinen" olur', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      await deviceReports(h, true);
      expect(h.state.childLockStale, isFalse);
      h.mqtt.setLink(MqttLinkState.reconnecting);
      await pumpEventQueue();
      expect(h.state.childLockStale, isTrue);
    });

    test('birden fazla pano: farklı değerler "mixed" (arayüz sürekli kilitli/açık arasında gitmez)', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      await deviceReports(h, true, uid: 'AHBU-S3-AAAA01');
      await deviceReports(h, false, uid: 'AHBU-S3-BBBB02');
      expect(h.state.childLockStatus, ChildLockStatus.mixed);
      await deviceReports(h, false, uid: 'AHBU-S3-AAAA01');
      expect(h.state.childLockStatus, ChildLockStatus.unlocked);
      await deviceReports(h, true, uid: 'AHBU-S3-AAAA01');
      await deviceReports(h, true, uid: 'AHBU-S3-BBBB02');
      expect(h.state.childLockStatus, ChildLockStatus.locked);
    });

    test('kilit alanı bozuk (null/çöp) olan state kilit durumunu DEĞİŞTİRMEZ', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      await deviceReports(h, true);
      h.mqtt.emitStateJson(<String, dynamic>{...stateJson(), 'child_lock': 'belki'});
      await pumpEventQueue();
      expect(h.state.childLockStatus, ChildLockStatus.locked);
      h.mqtt.emitStateJson(<String, dynamic>{...stateJson(), 'child_lock': null});
      await pumpEventQueue();
      expect(h.state.childLockStatus, ChildLockStatus.locked);
    });
  });

  group('yetki kapısı (metot düzeyinde)', () {
    for (final entry in <String, bool>{
      'owner': true,
      'resident': true,
      'service_user': true,
      'service_session': true,
      'guest': false,
      'admin': false,
    }.entries) {
      test('${entry.key}: ${entry.value ? 'değiştirebilir' : 'değiştiremez (REST\'e gidilmez)'}', () async {
        final isGuest = entry.key == 'guest';
        final home = isGuest
            ? HomeModel(
                id: kHomeA,
                name: 'Misafir',
                role: 'guest',
                mqttTopicId: 'h_test',
                guestValidFrom: kTestNow.subtract(const Duration(hours: 1)),
                guestValidUntil: kTestNow.add(const Duration(hours: 4)),
              )
            : null;
        final h = await readyHarness(
          role: entry.key,
          globalRole: entry.key == 'service_session' ? 'service_session' : (entry.key == 'service_user' ? 'service_user' : 'user'),
          home: home,
        );
        addTearDown(h.dispose);
        h.state.commandFailures.listen(failures.add);
        final dispatch = await h.state.setChildLock(true);
        await pumpEventQueue();
        expect(dispatch.ok, entry.value);
        expect(h.cloud.count('setChildLock'), entry.value ? 1 : 0);
        if (!entry.value) {
          expect(failures.single.reason, CommandFailureReason.forbidden);
          expect(dispatch.failure!.reason, CommandFailureReason.forbidden);
        }
      });
    }

    test('misafir kilit durumunu SALT-OKUNUR görür (REST + MQTT), değiştiremez', () async {
      final guest = HomeModel(
        id: kHomeA,
        name: 'Misafir',
        role: 'guest',
        mqttTopicId: 'h_test',
        guestValidFrom: kTestNow.subtract(const Duration(hours: 1)),
        guestValidUntil: kTestNow.add(const Duration(hours: 4)),
      );
      final h = await readyHarness(home: guest, configure: (h) => h.cloud.childLockValue = true);
      addTearDown(h.dispose);
      expect(h.cloud.count('getChildLock'), 1, reason: 'görüntüleme herkese');
      expect(h.state.childLockStatus, ChildLockStatus.locked);
      expect(h.cloud.count('getPeaceNotification'), 0, reason: 'huzur ayarı misafire kapalı');
      expect(h.state.capabilities.canChangeChildLock, isFalse);
    });

    test('süresi dolmuş misafir: kilit durumu yüklenmez, komut yok', () async {
      final expired = HomeModel(
        id: kHomeA,
        name: 'Eski',
        role: 'guest',
        mqttTopicId: 'h_test',
        guestValidUntil: kTestNow.subtract(const Duration(hours: 1)),
      );
      final h = await readyHarness(home: expired);
      addTearDown(h.dispose);
      expect(h.cloud.count('getChildLock'), 0);
      expect(h.state.childLockStatus, ChildLockStatus.unknown);
      expect((await h.state.setChildLock(true)).ok, isFalse);
    });
  });

  group('canlı kanal kopukken sunucu (REST) bayat cihaz değerinden tazedir', () {
    test('broker koptu + başka telefondan açıldı: REST değeri görünür (bayat cihaz değeri kalmaz)', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      await deviceReports(h, true); // pano kilitli bildirdi
      expect(h.state.childLockStatus, ChildLockStatus.locked);
      h.mqtt.setLink(MqttLinkState.reconnecting);
      await pumpEventQueue();
      expect(h.state.childLockStale, isTrue);

      h.cloud.childLockValue = false; // başka telefon açtı; sunucu köprü aracılığıyla biliyor
      h.cloud.childLockDevices = const <ChildLockDeviceInfo>[
        ChildLockDeviceInfo(deviceUuid: 'AHBU-S3-TEST01', online: true, enabled: false),
      ];
      await h.state.refresh(silent: true);
      await pumpEventQueue();

      expect(h.state.childLockStatus, ChildLockStatus.unlocked, reason: 'REST, kopuk kanaldaki bayat cihaz değerinden tazedir');
      expect(h.state.childLockStale, isTrue, reason: 'canlı kanal hâlâ yok: "son bilinen"');
      expect(h.state.childLockUpdatedAt, isNotNull);
    });

    test('broker koptu: REST pano satırları farklıysa "karışık"; kanal dönünce cihaz bildirimi esas olur', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      await deviceReports(h, true, uid: 'AHBU-S3-AAAA01');
      h.mqtt.setLink(MqttLinkState.reconnecting);
      await pumpEventQueue();

      h.cloud.childLockValue = false;
      h.cloud.childLockDevices = const <ChildLockDeviceInfo>[
        ChildLockDeviceInfo(deviceUuid: 'AHBU-S3-AAAA01', online: true, enabled: false),
        ChildLockDeviceInfo(deviceUuid: 'AHBU-S3-BBBB02', online: true, enabled: true),
      ];
      await h.state.refresh(silent: true);
      await pumpEventQueue();
      expect(h.state.childLockStatus, ChildLockStatus.mixed);

      h.mqtt.setLink(MqttLinkState.connected);
      await pumpEventQueue();
      await deviceReports(h, false, uid: 'AHBU-S3-BBBB02');
      expect(h.state.childLockStatus, ChildLockStatus.unlocked, reason: 'iki pano de bildirdi: cihaz bildirimi esas');
      expect(h.state.childLockStale, isFalse);
    });

    test('canlı kanal bağlıyken REST pano satırları cihaz değerini EZMEZ (değişmedi)', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      await deviceReports(h, true);
      h.cloud.childLockValue = false;
      h.cloud.childLockDevices = const <ChildLockDeviceInfo>[
        ChildLockDeviceInfo(deviceUuid: 'AHBU-S3-TEST01', online: true, enabled: false),
      ];
      await h.state.refresh(silent: true);
      await pumpEventQueue();
      expect(h.state.childLockStatus, ChildLockStatus.locked);
    });
  });

  group('MQTT kopukken (settle)', () {
    test('iletim başarılıysa değer korunur, hata gösterilmez; REST ile uzlaşılır', () async {
      final h = await readyHarness(brokerConnected: false);
      addTearDown(h.dispose);
      h.state.commandFailures.listen(failures.add);
      h.cloud.childLockValue = false;
      await h.state.refresh();
      expect(h.state.childLockStatus, ChildLockStatus.unlocked);

      h.cloud.childLockValue = true; // sunucu komutu işledi
      expect((await h.state.setChildLock(true)).ok, isTrue);
      expect(h.state.childLockStatus, ChildLockStatus.locked);
      await h.clock.elapse(const Duration(seconds: 6));
      expect(failures, isEmpty);
      expect(h.state.childLockStatus, ChildLockStatus.locked);
      expect(h.state.childLockPending, isFalse);
    });
  });

  group('sıfırlama', () {
    test('çıkış: kilit bilgisi ve bekleyen komut sıfırlanır', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      await deviceReports(h, true);
      await h.state.setChildLock(false);
      expect(h.state.childLockPending, isTrue);
      await h.state.logout();
      expect(h.state.childLockPending, isFalse);
      expect(h.state.childLockStatus, ChildLockStatus.unknown);
      expect(h.state.commandPipeline.hasPending, isFalse);
      expect(h.state.childLockUpdatedAt, isNull);
    });

    test('arka plana geçiş bekleyen komutu iptal eder (görünür değer gerçek değere döner); ön plana dönüşte yeniden eşitlenir', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      await deviceReports(h, false);
      await h.state.setChildLock(true);
      expect(h.state.childLockStatus, ChildLockStatus.locked);
      h.state.handleLifecycleState(AppLifecycleState.paused);
      expect(h.state.childLockPending, isFalse);
      expect(h.state.childLockStatus, ChildLockStatus.unlocked);
      final gets = h.cloud.count('getChildLock');
      h.state.handleLifecycleState(AppLifecycleState.resumed);
      await h.clock.elapse(const Duration(seconds: 1));
      expect(h.cloud.count('getChildLock'), greaterThan(gets), reason: 'ön plana dönüşte tek snapshot');
    });
  });

  group('doğrudan (LAN) mod', () {
    var deviceLock = false;
    var pollCount = 0;

    Map<String, dynamic> statusBody({bool withLock = true}) => <String, dynamic>{
          'device_name': 'Pano',
          'ip': '192.168.1.30',
          'wifi_connected': true,
          if (withLock) 'child_lock': deviceLock,
          'relays': <Map<String, dynamic>>[
            <String, dynamic>{'id': 1, 'name': 'Avize', 'type': 0, 'state': false},
          ],
          'shutters': <Map<String, dynamic>>[],
          'dis': <Map<String, dynamic>>[],
        };

    Future<StateHarness> lanHarness({bool lock = false}) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      deviceLock = lock;
      pollCount = 0;
      final h = StateHarness();
      h.state
        ..setCurrentUserForTesting(const UserModel(id: 'u', email: 'a@b.c', fullName: 'A', role: 'user'))
        ..setAuthStatusForTesting(AuthStatus.authenticated)
        ..setHomesForTesting(<HomeModel>[testHome()]);
      h.directMock.on('GET', '/api/status', (r) {
        pollCount++;
        return jsonResponse(statusBody());
      });
      await h.state.setMode(AppMode.direct);
      await h.state.setHost('192.168.1.30');
      h.direct.localKey = 'devicekey-1234';
      await h.state.refresh();
      return h;
    }

    test('POST {"enabled":bool} + X-Device-Key + application/json; poll cihazın uyguladığını doğrular', () async {
      final h = await lanHarness();
      addTearDown(h.dispose);
      h.state.commandFailures.listen(failures.add);
      expect(h.state.childLockStatus, ChildLockStatus.unlocked);
      h.directMock.on('POST', '/api/child-lock', (r) {
        // cihaz "queued" döner; kilidi bir sonraki turda uygular (sahte saatle: gerçek zamana bağlı yarış yok)
        final enabled = r.json!['enabled'] as bool;
        h.clock.timer(const Duration(milliseconds: 100), () => deviceLock = enabled);
        return jsonResponse(<String, dynamic>{'success': true, 'status': 'queued', 'child_lock': r.json!['enabled']});
      });
      deviceLock = false;
      final future = h.state.setChildLock(true);
      expect(h.state.childLockStatus, ChildLockStatus.locked);
      expect((await future).ok, isTrue);
      final post = h.directMock.where('POST', '/api/child-lock').single;
      expect(post.json, <String, dynamic>{'enabled': true});
      expect(post.headers['X-Device-Key'], 'devicekey-1234');
      expect(post.headers['Content-Type'], contains('application/json'));
      expect(h.state.childLockPending, isTrue, reason: '"queued" uygulandı demek değil');

      deviceLock = true; // cihaz uyguladı
      await h.clock.elapse(const Duration(milliseconds: 1800));
      expect(h.state.childLockPending, isFalse);
      expect(h.state.childLockStatus, ChildLockStatus.locked);
      expect(failures, isEmpty);
    });

    test('cihaz uygulamazsa 2.5 sn içinde geri alınır', () async {
      final h = await lanHarness();
      addTearDown(h.dispose);
      h.state.commandFailures.listen(failures.add);
      h.directMock.on('POST', '/api/child-lock', (r) => jsonResponse(<String, dynamic>{'status': 'queued'}));
      await h.state.setChildLock(true);
      await h.clock.elapse(const Duration(milliseconds: 2800));
      expect(h.state.childLockPending, isFalse);
      expect(h.state.childLockStatus, ChildLockStatus.unlocked);
      expect(failures.single.reason, CommandFailureReason.timeout);
    });

    for (final scenario in <(int, Map<String, dynamic>, CommandFailureReason)>[
      (400, <String, dynamic>{'error': 'invalid_value'}, CommandFailureReason.rejected),
      (401, <String, dynamic>{'error': 'unauthorized'}, CommandFailureReason.forbidden),
      (423, <String, dynamic>{'error': 'locked', 'retry_after': 60}, CommandFailureReason.rateLimited),
      (403, <String, dynamic>{'error': 'unprovisioned'}, CommandFailureReason.rejected),
    ]) {
      test('POST ${scenario.$1} -> anında geri alma', () async {
        final h = await lanHarness(lock: true);
        addTearDown(h.dispose);
        h.state.commandFailures.listen(failures.add);
        expect(h.state.childLockStatus, ChildLockStatus.locked);
        h.directMock.on('POST', '/api/child-lock', (r) => jsonResponse(scenario.$2, status: scenario.$1));
        final dispatch = await h.state.setChildLock(false);
        await pumpEventQueue();
        expect(dispatch.ok, isFalse);
        expect(h.state.childLockStatus, ChildLockStatus.locked);
        expect(h.state.childLockPending, isFalse);
        expect(failures.single.reason, scenario.$3);
      });
    }

    test('hızlı ardışık aç/kapat: istek koruması (tek uçuş + son niyet), kilit durumu tutarlı kalır', () async {
      final h = await lanHarness();
      addTearDown(h.dispose);
      final gate = Completer<void>();
      var posts = 0;
      h.directMock.on('POST', '/api/child-lock', (r) async {
        posts++;
        if (posts == 1) await gate.future;
        return jsonResponse(<String, dynamic>{'status': 'queued'});
      });
      final a = h.state.setChildLock(true);
      final b = h.state.setChildLock(false);
      final c = h.state.setChildLock(true);
      await pumpEventQueue();
      expect(posts, 1, reason: 'ilk istek dönmeden ikincisi gönderilmez');
      gate.complete();
      await Future.wait<CommandDispatch>(<Future<CommandDispatch>>[a, b, c]);
      expect(posts, lessThanOrEqualTo(2));
      expect(h.directMock.where('POST', '/api/child-lock').last.json, <String, dynamic>{'enabled': true});
      expect(h.state.childLockStatus, ChildLockStatus.locked);
    });

    test('kısıtlı (anahtarsız) status özeti çocuk kilidini SIFIRLAMAZ', () async {
      final h = await lanHarness(lock: true);
      addTearDown(h.dispose);
      expect(h.state.childLockStatus, ChildLockStatus.locked);
      h.directMock.on('GET', '/api/status', (r) => jsonResponse(statusBody(withLock: false)));
      await h.state.refresh();
      expect(h.state.childLockStatus, ChildLockStatus.locked, reason: 'child_lock taşımayan yanıt bilgi vermez');
    });

    test('değişmeyen yoklamalar arayüzü yeniden çizdirmez (notifyListeners yok)', () async {
      final h = await lanHarness();
      addTearDown(h.dispose);
      var notifications = 0;
      h.state.addListener(() => notifications++);
      final polls = pollCount;
      await h.clock.elapse(const Duration(seconds: 8)); // ~5 yoklama
      expect(pollCount, greaterThan(polls + 2), reason: 'yoklamalar çalıştı');
      expect(notifications, 0, reason: 'durum aynıyken bildirim yok');

      deviceLock = true; // gerçek değişim -> bildirim
      await h.clock.elapse(const Duration(milliseconds: 1600));
      expect(notifications, greaterThan(0));
      expect(h.state.childLockStatus, ChildLockStatus.locked);
    });
  });
}
