import 'dart:async';

import 'package:ev_otomasyon/models/automation_models.dart';
import 'package:ev_otomasyon/models/capabilities.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/models/scheduled_rule_model.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/support.dart';

/// PF-20 / PF-25 (WP-STATE, S6): türetilmiş değerler (`relayItems`, `shutterItems`, `status`, `scheduledRules`,
/// `capabilities`, salt-okunur liste görünümleri) girdileri değişmedikçe AYNI nesneyi döndürür; girdi
/// değişince (MQTT/REST/LAN, bekleyen komut, geri alma, rol/ev/oturum/misafir süresi, `...ForTesting`
/// ayarlayıcıları) YENİ ve doğru nesne. İnvalidasyon kaçırma = bayat görünüm: bu dosya onu yakalar.
void main() {
  Future<void> settle() => pumpEventQueue();

  Map<String, dynamic> live({Map<int, bool> relays = const <int, bool>{1: false, 2: false, 5: false, 6: false}, int pos = 30, bool moving = false}) =>
      stateJson(
        relays: relays,
        shutters: <Map<String, dynamic>>[
          <String, dynamic>{'pair': 2, 'pos': pos, 'moving': moving, 'dir': moving ? 1 : 0, 'target': moving ? 100 : 255},
        ],
      );

  bool relayState(StateHarness h, int id) => h.state.relayItems.firstWhere((r) => r.id == id).state;

  group('bulut: relayItems / shutterItems', () {
    test('girdi değişmedikçe AYNI nesne (identical)', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);

      expect(identical(h.state.relayItems, h.state.relayItems), isTrue);
      expect(identical(h.state.shutterItems, h.state.shutterItems), isTrue);
      expect(identical(h.state.cloudEndpoints, h.state.cloudEndpoints), isTrue);
      expect(h.state.relayItems.map((r) => r.id), <int>[1, 2, 5, 6]);
      expect(h.state.shutterItems.single.pair, 2);
    });

    test('özdeş MQTT iletileri önbelleği BOZMAZ; değişen değer yeni liste + doğru değer üretir', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.mqtt.emitStateJson(live());
      await settle();
      final relays = h.state.relayItems;
      final shutters = h.state.shutterItems;

      h.mqtt.emitStateJson(live()); // özdeş: görünür değişim yok
      await settle();
      expect(identical(h.state.relayItems, relays), isTrue, reason: 'eskiden her erişimde yeni liste kurulurdu');
      expect(identical(h.state.shutterItems, shutters), isTrue);

      h.mqtt.emitStateJson(live(relays: const <int, bool>{1: true, 2: false, 5: false, 6: false}));
      await settle();
      expect(identical(h.state.relayItems, relays), isFalse);
      expect(relayState(h, 1), isTrue);
      expect(relays.firstWhere((r) => r.id == 1).state, isFalse, reason: 'eski anlık görüntü değişmez');
      expect(identical(h.state.shutterItems, h.state.shutterItems), isTrue);

      h.mqtt.emitStateJson(live(relays: const <int, bool>{1: true, 2: false, 5: false, 6: false}, pos: 55, moving: true));
      await settle();
      expect(h.state.shutterItems.single.pos, 55);
      expect(h.state.shutterItems.single.isMoving, isTrue);
    });

    test('iyimser röle komutu görünür; geri alma (onay yok) gerçek değeri geri getirir', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.mqtt.emitStateJson(live());
      await settle();
      final before = h.state.relayItems;

      await h.state.toggleRelay(1);
      expect(h.state.commandPipeline.hasPending, isTrue);
      expect(relayState(h, 1), isTrue, reason: 'iyimser hedef (bayat önbellek YOK)');
      expect(identical(h.state.relayItems, before), isFalse);
      final optimistic = h.state.relayItems;
      expect(identical(h.state.relayItems, optimistic), isTrue);

      await h.clock.elapse(const Duration(seconds: 3)); // cihaz onaylamadı: geri alma
      await settle();
      expect(h.state.commandPipeline.hasPending, isFalse);
      expect(relayState(h, 1), isFalse, reason: 'geri alma sonrası gerçek değer');
      expect(identical(h.state.relayItems, optimistic), isFalse);
    });

    test('iyimser komut cihaz onayıyla kalıcılaşır (onaylayan state sonrası liste doğru)', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.mqtt.emitStateJson(live());
      await settle();

      await h.state.toggleRelay(2);
      h.mqtt.emitStateJson(live(relays: const <int, bool>{1: false, 2: true, 5: false, 6: false}));
      await settle();

      expect(h.state.commandPipeline.hasPending, isFalse);
      expect(relayState(h, 2), isTrue);
      await h.clock.elapse(const Duration(seconds: 5));
      expect(relayState(h, 2), isTrue, reason: 'onaylanan değer geri alınmadı');
    });

    test('panjur: iyimser konum ve hareket görünür; geri alınınca gerçek konum', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.mqtt.emitStateJson(live());
      await settle();
      expect(h.state.shutterItems.single.pos, 30);

      await h.state.setShutterPosition(2, 80);
      expect(h.state.shutterItems.single.pos, 80, reason: 'iyimser konum');
      await h.clock.elapse(const Duration(seconds: 3));
      await settle();
      expect(h.state.shutterItems.single.pos, 30, reason: 'geri alma: gerçek konum');

      await h.state.cmdShutter(2, 'up');
      expect(h.state.shutterItems.single.isMoving, isTrue, reason: 'iyimser hareket');
      expect(h.state.shutterItems.single.direction, 1);
      await h.clock.elapse(const Duration(seconds: 3));
      await settle();
      expect(h.state.shutterItems.single.isMoving, isFalse);
    });

    test('REST yenilemesi (uç noktalar değişti) listeleri günceller', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      final before = h.state.relayItems;
      h.cloud.endpoints[kHomeA] = testEndpoints().map((e) => e.channel == 5 ? e.copyWith(currentState: true) : e).toList();

      await h.state.refresh(silent: true);
      await settle();

      expect(identical(h.state.relayItems, before), isFalse);
      expect(relayState(h, 5), isTrue);
      expect(h.state.openLightsCount, 1);
    });

    test('ev değişimi eski evin listelerini temizler (önbellek eski evi göstermez)', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      expect(h.state.relayItems, isNotEmpty);
      h.cloud.homes = <HomeModel>[testHome(), testHome(id: kHomeB, name: 'Ev B', topic: 'h_b')];
      h.cloud.endpoints[kHomeB] = <EndpointModel>[
        EndpointModel(id: 'b1', homeId: kHomeB, channel: 1, name: 'B Lamba', room: 'Genel', endpointType: 'light', currentState: true),
      ];
      await h.state.fetchHomes(autoSelect: false);
      final gate = Completer<void>();
      h.cloud.fetchEndpointsGate = gate;

      final switching = h.state.selectHome(h.state.homeById(kHomeB)!);
      await settle();
      expect(h.state.relayItems, isEmpty, reason: 'yeni evin uç noktaları gelene kadar eski ev görünmez');
      expect(h.state.shutterItems, isEmpty);
      gate.complete();
      await switching;

      expect(h.state.relayItems.map((r) => r.id), <int>[1]);
      expect(h.state.relayItems.single.name, 'B Lamba');
      expect(h.state.shutterItems, isEmpty);
    });

    test('çıkış listeleri temizler', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      expect(h.state.relayItems, isNotEmpty);

      await h.state.logout();

      expect(h.state.relayItems, isEmpty);
      expect(h.state.shutterItems, isEmpty);
      expect(h.state.status, isNull);
    });
  });

  group('doğrudan (LAN) mod: status / relayItems / shutterItems', () {
    Map<String, dynamic> statusBody({bool r3 = false, int pos = 20}) => <String, dynamic>{
          'device_name': 'Pano',
          'ip': '192.168.1.30',
          'wifi_connected': true,
          'child_lock': false,
          'relays': <Map<String, dynamic>>[
            <String, dynamic>{'id': 1, 'name': 'Avize', 'type': 1, 'state': false},
            <String, dynamic>{'id': 2, 'name': 'Avize Aşağı', 'type': 2, 'state': false},
            <String, dynamic>{'id': 3, 'name': 'Mutfak', 'type': 0, 'state': r3},
            <String, dynamic>{'id': 4, 'name': 'Spot', 'type': 0, 'state': false},
          ],
          'shutters': <Map<String, dynamic>>[
            <String, dynamic>{'pair': 1, 'pos': pos, 'is_moving': false, 'dir': 0, 'target': 255},
          ],
          'dis': <Map<String, dynamic>>[],
        };

    Future<StateHarness> lan() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final h = StateHarness();
      h.state
        ..setCurrentUserForTesting(const UserModel(id: 'u', email: 'a@b.c', fullName: 'A', role: 'user'))
        ..setAuthStatusForTesting(AuthStatus.authenticated)
        ..setHomesForTesting(<HomeModel>[testHome()]);
      h.directMock.on('GET', '/api/status', (r) => jsonResponse(statusBody()));
      await h.state.setMode(AppMode.direct);
      await h.state.setHost('192.168.1.30');
      h.direct.localKey = 'devicekey-1234';
      await h.state.refresh();
      return h;
    }

    test('girdi değişmedikçe aynı nesne; yoklama değeri değişince yeni ve doğru', () async {
      final h = await lan();
      addTearDown(h.dispose);
      expect(identical(h.state.status, h.state.status), isTrue);
      expect(identical(h.state.relayItems, h.state.relayItems), isTrue);
      expect(identical(h.state.shutterItems, h.state.shutterItems), isTrue);
      expect(h.state.relayItems.map((r) => r.id), <int>[3, 4]);
      expect(relayState(h, 3), isFalse);
      final before = h.state.relayItems;

      h.directMock.on('GET', '/api/status', (r) => jsonResponse(statusBody(r3: true, pos: 60)));
      await h.clock.elapse(const Duration(seconds: 3));

      expect(identical(h.state.relayItems, before), isFalse);
      expect(relayState(h, 3), isTrue);
      expect(h.state.shutterItems.single.pos, 60);
      expect(h.state.status!.relayById(3)!.state, isTrue);
    });

    test('iyimser LAN komutu görünür ve geri alınır; durum bayat kalmaz', () async {
      final h = await lan();
      addTearDown(h.dispose);
      h.directMock.on('POST', '/api/relay', (r) => jsonResponse(<String, dynamic>{'status': 'ok'}));

      final result = h.state.toggleRelay(3);
      expect(h.state.status!.relayById(3)!.state, isTrue, reason: 'iyimser');
      expect(relayState(h, 3), isTrue);
      await result;

      await h.clock.elapse(const Duration(seconds: 4)); // cihaz hâlâ kapalı bildiriyor: geri alma
      expect(h.state.commandPipeline.hasPending, isFalse);
      expect(h.state.status!.relayById(3)!.state, isFalse, reason: 'gerçek değer');
      expect(relayState(h, 3), isFalse);
    });

    test('moda göre kaynak değişir: buluta dönünce status yok, bulut listeleri', () async {
      final h = await lan();
      addTearDown(h.dispose);
      expect(h.state.relayItems.map((r) => r.id), <int>[3, 4]);

      await h.state.setMode(AppMode.cloud);

      expect(h.state.status, isNull);
      expect(h.state.relayItems, isEmpty, reason: 'bulutta ev uç noktaları henüz yok (ForTesting ev, REST yok)');
    });

    test('...ForTesting ayarlayıcıları SENKRON bildirir ve görünümü geçersiz kılar', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final h = StateHarness();
      addTearDown(h.dispose);
      var n = 0;
      h.state.addListener(() => n++);

      h.state.setModeForTesting(AppMode.direct);
      expect(n, 1);
      expect(h.state.relayItems, isEmpty);
      h.state.setStatusForTesting(DeviceStatus.fromJson(statusBody(r3: true)));
      expect(n, 2, reason: 'senkron bildirim');
      expect(h.state.relayItems.map((r) => r.id), <int>[3, 4]);
      expect(relayState(h, 3), isTrue);

      h.state.setStatusForTesting(DeviceStatus.fromJson(statusBody()));
      expect(n, 3);
      expect(relayState(h, 3), isFalse, reason: 'ayarlayıcı sonrası önbellek bayat kalmadı');

      h.state.setModeForTesting(AppMode.cloud);
      h.state.setCloudEndpointsForTesting(testEndpoints());
      expect(n, 5);
      expect(h.state.relayItems.map((r) => r.id), <int>[1, 2, 5, 6]);
      h.state.setCloudEndpointsForTesting(testEndpoints().where((e) => e.channel != 6).toList());
      expect(n, 6);
      expect(h.state.relayItems.map((r) => r.id), <int>[1, 2, 5]);
    });
  });

  group('scheduledRules ve salt-okunur görünümler', () {
    ScheduledRule rule(String id) => ScheduledRule(
          id: id,
          homeId: kHomeA,
          channel: 1,
          channelType: 'relay',
          action: 'on',
          hour: 7,
          minute: 30,
          daysOfWeek: const <int>[1, 2, 3],
          enabled: true,
        );

    test('scheduledRules aynı nesne; kural eklenince/silinince yenilenir; değiştirilemez', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.cloud.rules = <ScheduledRule>[rule('r1')];
      await h.state.fetchScheduledRules();
      final first = h.state.scheduledRules;

      expect(first.map((r) => r.id), <String>['r1']);
      expect(identical(h.state.scheduledRules, first), isTrue);
      expect(() => first.add(rule('x')), throwsUnsupportedError);

      h.cloud.rules = <ScheduledRule>[rule('r1'), rule('r2')];
      await h.state.fetchScheduledRules();
      expect(h.state.scheduledRules.map((r) => r.id), <String>['r1', 'r2']);
      expect(identical(h.state.scheduledRules, first), isFalse);

      h.state.setScheduledRulesForTesting(<ScheduledRule>[rule('t1')]);
      expect(h.state.scheduledRules.map((r) => r.id), <String>['t1']);
    });

    test('envanter / aboneler / çevrimdışı panolar: aynı nesne, değiştirilemez, atamada yenilenir', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      expect(identical(h.state.inventoryDevices, h.state.inventoryDevices), isTrue);
      expect(identical(h.state.serviceSubscribers, h.state.serviceSubscribers), isTrue);
      expect(identical(h.state.inventoryStats, h.state.inventoryStats), isTrue);
      expect(identical(h.state.childLockOfflineDevices, h.state.childLockOfflineDevices), isTrue);
      expect(() => h.state.serviceSubscribers.add(<String, dynamic>{}), throwsUnsupportedError);

      final before = h.state.serviceSubscribers;
      h.state.setServiceSubscribersForTesting(<Map<String, dynamic>>[
        <String, dynamic>{'id': 's1'},
      ]);
      expect(h.state.serviceSubscribers, hasLength(1));
      expect(identical(h.state.serviceSubscribers, before), isFalse);
    });
  });

  group('capabilities', () {
    HomeModel guest({Duration from = const Duration(hours: -1), Duration until = const Duration(hours: 2)}) => HomeModel(
          id: kHomeA,
          name: 'Misafir',
          role: 'guest',
          mqttTopicId: 'h_test',
          guestValidFrom: kTestNow.add(from),
          guestValidUntil: kTestNow.add(until),
        );

    test('girdi değişmedikçe aynı nesne; yetkiler doğru', () async {
      final h = await readyHarness(role: 'owner');
      addTearDown(h.dispose);

      final caps = h.state.capabilities;
      expect(identical(h.state.capabilities, caps), isTrue);
      expect(caps.isOwner, isTrue);
      expect(caps.canInvite, isTrue);
      h.clock.advance(const Duration(hours: 3)); // owner için zaman etkisiz
      expect(identical(h.state.capabilities, caps), isTrue);
    });

    test('ev sahibinin rolü sunucuda değişince (owner -> resident) yetkiler güncellenir', () async {
      final h = await readyHarness(role: 'owner');
      addTearDown(h.dispose);
      final owner = h.state.capabilities;
      expect(owner.canInvite, isTrue);

      h.cloud.homes = <HomeModel>[testHome(role: 'resident')];
      await h.state.fetchHomes(autoSelect: false);
      await settle();

      final resident = h.state.capabilities;
      expect(resident.isOwner, isFalse);
      expect(resident.isResident, isTrue);
      expect(resident.canInvite, isFalse);
      expect(resident, isNot(equals(owner)));
    });

    test('aynı içerikli yeni ev nesnesi (her fetchHomes) eşit yetki üretir', () async {
      final h = await readyHarness(role: 'owner');
      addTearDown(h.dispose);
      final before = h.state.capabilities;

      await h.state.fetchHomes(autoSelect: false);
      await settle();

      expect(h.state.capabilities, equals(before));
      expect(h.state.capabilities.hashCode, before.hashCode);
    });

    test('misafir süresi dolunca (yalnız zaman geçerek) yetkiler kapanır; pencere içinde aynı nesne', () async {
      final h = await readyHarness(home: guest());
      addTearDown(h.dispose);
      final valid = h.state.capabilities;
      expect(valid.isGuest, isTrue);
      expect(valid.isGuestExpired, isFalse);
      expect(valid.canControlDevices, isTrue);

      h.clock.advance(const Duration(minutes: 30));
      expect(identical(h.state.capabilities, valid), isTrue, reason: 'pencere içinde zaman geçmesi nesneyi değiştirmez');
      expect(h.state.isGuestExpired, isFalse);

      h.clock.advance(const Duration(hours: 3)); // pencere bitti (süre dolumu zamanlayıcısı da tetiklenir)
      await settle();
      expect(h.state.capabilities.isGuestExpired, isTrue);
      expect(h.state.capabilities.canControlDevices, isFalse);
      expect(h.state.isGuestExpired, isTrue);
    });

    test('henüz başlamamış misafir penceresi başlayınca yetkiler açılır (zamanla geçiş)', () async {
      final h = await readyHarness(home: guest(from: const Duration(hours: 1), until: const Duration(hours: 4)));
      addTearDown(h.dispose);
      expect(h.state.capabilities.isGuestExpired, isTrue, reason: 'pencere henüz başlamadı');

      h.clock.advance(const Duration(hours: 2));
      expect(h.state.capabilities.isGuestExpired, isFalse);
      expect(h.state.capabilities.isGuest, isTrue);
    });

    test('çıkış: yetkisiz; yeni giriş: yeniden hesaplanır', () async {
      final h = await readyHarness(role: 'owner');
      addTearDown(h.dispose);
      expect(h.state.capabilities.isOwner, isTrue);

      await h.state.logout();
      expect(h.state.capabilities, const Capabilities.none());

      h.cloud.homes = <HomeModel>[testHome(role: 'resident')];
      h.cloud.endpoints[kHomeA] = testEndpoints();
      expect(await h.state.login('a@b.c', 'parola-1234'), isTrue);
      await settle();
      expect(h.state.capabilities.isResident, isTrue);
      expect(h.state.capabilities.isOwner, isFalse);
    });

    test('kullanıcının küresel rolü değişince (...ForTesting) yetkiler güncellenir', () async {
      final h = await readyHarness(role: 'owner');
      addTearDown(h.dispose);
      expect(h.state.capabilities.isSuperUser, isFalse);

      h.state.setCurrentUserForTesting(const UserModel(id: 'user-1', email: 'a@b.c', fullName: 'A', role: 'super_user'));
      expect(h.state.capabilities.isSuperUser, isTrue);
    });
  });

  group('Capabilities ==/hashCode (bit maskesi) toMap eşitliğiyle AYNI anlamı taşır', () {
    test('tüm rol kombinasyonları: (a == b) <=> mapEquals(a.toMap(), b.toMap()); eşitse hashCode eşit', () {
      final now = kTestNow;
      final all = <Capabilities>[
        const Capabilities.none(),
        const Capabilities.localKeyHolder(),
        for (final g in <String?>[null, 'user', 'service_user', 'super_user', 'service_session', 'bilinmeyen'])
          for (final r in <String?>[null, 'owner', 'resident', 'guest', 'service_user', 'service_session', 'bilinmeyen'])
            for (final window in <(DateTime?, DateTime?)>[
              (null, null),
              (now.subtract(const Duration(hours: 1)), now.add(const Duration(hours: 1))),
              (now.add(const Duration(hours: 1)), now.add(const Duration(hours: 2))),
              (now.subtract(const Duration(hours: 2)), now.subtract(const Duration(hours: 1))),
            ])
              Capabilities(globalRole: g, homeRole: r, guestValidFrom: window.$1, guestValidUntil: window.$2, now: now),
      ];
      expect(all.length, greaterThan(100));
      expect(all.first.toMap().length, 36, reason: '32 temel + 4 güvenlik bayrağı');

      final mismatches = <String>[];
      var equalPairs = 0;
      var unequalPairs = 0;
      for (final a in all) {
        final aMap = a.toMap();
        for (final b in all) {
          final byMap = mapEquals(aMap, b.toMap());
          if ((a == b) != byMap) mismatches.add('$a ?= $b (toMap: $byMap)');
          if (byMap) {
            equalPairs++;
            if (a.hashCode != b.hashCode) mismatches.add('hashCode: $a');
          } else {
            unequalPairs++;
          }
        }
      }
      expect(mismatches, isEmpty);
      expect(equalPairs, greaterThan(all.length), reason: 'kontrol boş geçmesin: farklı nesneler de eşit olabilir');
      expect(unequalPairs, greaterThan(all.length), reason: 'kontrol boş geçmesin: farklı yetkiler eşitsiz olmalı');
    });
  });

  group('PF-25: shutterBaseName', () {
    test('yön eki atılır; ek yoksa ad aynen; boş kalırsa yedek ad', () {
      expect(shutterBaseName('Salon Panjur Yukarı'), 'Salon Panjur');
      expect(shutterBaseName('Salon Panjur Aşağı'), 'Salon Panjur');
      expect(shutterBaseName('Salon (Aşağı)'), 'Salon');
      expect(shutterBaseName('Mutfak up'), 'Mutfak');
      expect(shutterBaseName('Mutfak DOWN'), 'Mutfak');
      expect(shutterBaseName('Yatak asagi'), 'Yatak');
      expect(shutterBaseName('Balkon yukari'), 'Balkon');
      expect(shutterBaseName('Salon Panjur'), 'Salon Panjur');
      expect(shutterBaseName('Yukarı', fallback: 'Panjur 3'), 'Panjur 3');
      expect(shutterBaseName('', fallback: 'Panjur 1'), 'Panjur 1');
    });

    test('çok sayıda çağrı aynı sonucu verir (düzenli ifade yeniden kurulmadan)', () {
      final results = <String>{
        for (var i = 0; i < 2000; i++) shutterBaseName('Oda $i Panjur Yukarı'),
      };
      expect(results.length, 2000);
      expect(results.contains('Oda 1999 Panjur'), isTrue);
    });
  });
}
