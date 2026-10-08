import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/dashboard/apartment_dashboard.dart';
import 'package:ev_otomasyon/ui/pages/device_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/support.dart';

/// Doğrudan (LAN) kip ve aktif ev (2026-10-08 düzeltmeleri):
///
/// * kullanim-1: doğrudan kipte yeniden açılışta aktif ev seçilir; ev başına LAN panosu hatırlanır; buluta dönüş her
///   zaman görünür; aktif ev listeden düşünce bulut kipine geçilir.
/// * kullanim-3: ev değişince önceki evin panosu (adres + anahtar) kullanılmaz; adresteki pano seçili daireye ait değilse
///   durum gösterilmez ve komut gitmez.
/// * bireysel-5: girişsiz yerel kipte adres/anahtar kartı görünür; elle girilen anahtar kalıcıdır.
void main() {
  const uidA = 'AHBU-S3-TEST01';
  const uidB = 'AHBU-S3-BBBB01';

  Map<String, dynamic> lanStatus({String device = uidA}) => <String, dynamic>{
        'device': device,
        'device_name': 'Pano',
        'ip': '192.168.1.30',
        'wifi_connected': true,
        'child_lock': false,
        'relays': <Map<String, dynamic>>[
          <String, dynamic>{'id': 1, 'name': 'Avize', 'type': 0, 'state': false},
          <String, dynamic>{'id': 2, 'name': 'Spot', 'type': 0, 'state': false},
        ],
        'shutters': <dynamic>[],
        'dis': <dynamic>[],
      };

  Map<String, dynamic> restricted({String device = uidA}) => <String, dynamic>{
        'device': device,
        'name': 'Pano',
        'fw': '1.3.0',
        'provisioned': true,
        'wifi_connected': true,
      };

  String? keyHeader(RecordedRequest r) {
    for (final e in r.headers.entries) {
      if (e.key.toLowerCase() == 'x-device-key') return e.value;
    }
    return null;
  }

  const user = UserModel(id: 'user-1', email: 'a@b.c', fullName: 'Ayşe', role: 'user');

  group('kullanim-1: doğrudan kipte açılış', () {
    test('saklı oturum + önbellekteki ev + hatırlanan LAN panosu: aktif ev seçilir, anahtar yüklenir, komut LAN\'a gider',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'saved_app_mode': 'direct',
        'saved_esp_host': '192.168.1.30',
        'lan_device_$kHomeA': uidA,
      });
      final clock = FakeClock();
      final storage = FakeStorage();
      await storage.saveAuthToken('access-1');
      await storage.saveRefreshToken('refresh-1');
      await storage.saveUser(user);
      await storage.saveHomesCache(user.id, <HomeModel>[testHome()]);
      await storage.saveLocalKey(uidA, 'devicekey-1234');
      // İnternet yok: ev listesi ve cihaz listesi alınamaz.
      final cloud = FakeCloudApi(clock: clock)
        ..fetchHomesError = ApiException.network()
        ..devicesError = ApiException.network()
        ..localKeyError = ApiException.network();
      final h = StateHarness(autoInit: true, clock: clock, cloud: cloud, storage: storage);
      addTearDown(h.dispose);
      h.directMock.on('GET', '/api/status', (r) => jsonResponse(lanStatus()));
      h.directMock.on('POST', '/api/relay', (r) => jsonResponse(<String, dynamic>{'ok': true}));

      await h.state.ready;
      await pumpEventQueue(times: 40);

      expect(h.state.mode, AppMode.direct);
      expect(h.state.activeHome?.id, kHomeA, reason: 'aktif ev seçilmeli (komut kapıları ev rolüne bakar)');
      expect(h.state.hasLocalKey, isTrue, reason: 'hatırlanan LAN panosunun anahtarı depodan yüklenir');
      expect(h.state.status, isNotNull);

      expect(await h.state.setRelay(1, true), isTrue);
      await pumpEventQueue();
      expect(h.directMock.count('POST', '/api/relay'), 1);
      expect(h.cloud.sentCommands, isEmpty);
    });

    test('anahtar çözülünce ev başına LAN panosu hatırlanır (lan_device_<ev>)', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.directMock.on('GET', '/api/status', (r) => jsonResponse(lanStatus()));
      await h.state.setMode(AppMode.direct);
      await pumpEventQueue();
      expect(h.state.hasLocalKey, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('lan_device_$kHomeA'), uidA);
    });

    test('doğrudan kipte aktif ev listeden düşünce bulut kipine geçilir', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.directMock.on('GET', '/api/status', (r) => jsonResponse(lanStatus()));
      await h.state.setMode(AppMode.direct);
      await pumpEventQueue();
      expect(h.state.mode, AppMode.direct);

      h.cloud.homes = <HomeModel>[];
      await h.state.fetchHomes(autoSelect: false);
      await pumpEventQueue(times: 40);

      expect(h.state.activeHome, isNull);
      expect(h.state.mode, AppMode.cloud);
    });
  });

  group('kullanim-1: buluta dönüş her zaman görünür', () {
    Future<StateHarness> directGuest(WidgetTester tester, {required Map<String, dynamic> status, int code = 200}) async {
      final h = (await tester.runAsync(() async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final h = StateHarness();
        h.state
          ..setCurrentUserForTesting(user)
          ..setAuthStatusForTesting(AuthStatus.authenticated)
          ..setHomesForTesting(<HomeModel>[
            HomeModel(
              id: kHomeA,
              name: 'Ev A',
              role: 'guest',
              guestValidFrom: kTestNow.subtract(const Duration(hours: 1)),
              guestValidUntil: kTestNow.add(const Duration(hours: 5)),
            ),
          ])
          ..setModeForTesting(AppMode.direct);
        h.directMock.on('GET', '/api/status', (r) => jsonResponse(status, status: code));
        h.state.setSelectedDeviceForTesting(uuid: '', ip: '192.168.1.30');
        await h.state.refresh();
        return h;
      }))!;
      addTearDown(h.dispose);
      expect(h.state.capabilities.canSwitchMode, isFalse, reason: 'misafir mod değiştiremez');
      await pumpApp(tester, state: h.state, child: const Scaffold(body: ApartmentDashboard()));
      return h;
    }

    testWidgets('anahtarsız (kısıtlı özet) kartında giriş yapmış kullanıcıya "Bulut moduna geç"', (tester) async {
      await directGuest(tester, status: restricted());
      expect(find.byKey(const Key('error_card')), findsOneWidget);
      expect(find.byKey(const Key('btn_go_cloud')), findsOneWidget);
    });

    testWidgets('cihaza ulaşılamayan kartta da "Bulut moduna geç" (canSwitchMode yok)', (tester) async {
      final h = await directGuest(tester, status: <String, dynamic>{'error': 'busy'}, code: 503);
      expect(h.state.connState, ConnectionStateEnum.offline);
      expect(find.byKey(const Key('btn_go_cloud')), findsOneWidget);
    });
  });

  group('kullanim-3: ev değişince önceki evin panosu kullanılmaz', () {
    test('A evinde anahtarlı doğrudan kip; B seçilince A\'nın anahtarıyla istek yok, uyuşmazlık hatası, komut reddi',
        () async {
      final h = await readyHarness(configure: (h) {
        h.cloud.homes = <HomeModel>[testHome(), testHome(id: kHomeB, name: 'Ev B', topic: 'h_b')];
        h.cloud.endpoints[kHomeB] = testEndpoints(homeId: kHomeB, deviceUuid: uidB);
        h.cloud.devicesByHome[kHomeB] = <DeviceInfo>[
          const DeviceInfo(deviceUuid: uidB, name: 'Pano B', online: true, firmware: '1.3.0'),
        ];
        h.cloud.localKeyValue = 'key-A-12345';
      });
      addTearDown(h.dispose);
      // Adresteki pano (192.168.1.30) A evinin panosu: hangi anahtarla sorulursa sorulsun kendini bildirir.
      h.directMock.on('GET', '/api/status', (r) => jsonResponse(lanStatus(device: uidA)));
      await h.state.setMode(AppMode.direct);
      await h.state.setHost('192.168.1.30');
      await pumpEventQueue();
      expect(h.state.status?.uid, uidA);
      expect(h.direct.localKey, 'key-A-12345');

      h.cloud.localKeyValue = 'key-B-12345';
      h.directMock.requests.clear();
      final failures = <CommandFailure>[];
      final sub = h.state.commandFailures.listen(failures.add);
      addTearDown(sub.cancel);

      await h.state.selectHome(h.state.homeById(kHomeB)!);
      await pumpEventQueue(times: 40);

      final statusRequests = h.directMock.where('GET', '/api/status');
      expect(statusRequests, isNotEmpty);
      expect(statusRequests.map(keyHeader), isNot(contains('key-A-12345')), reason: 'A\'nın anahtarı B evinde kullanılmaz');
      expect(h.state.status, isNull, reason: 'adresteki pano B evine ait değil');
      expect(h.state.directError, 'Bu adresteki pano seçili daireye ait değil. Adresi kontrol edin.');

      expect(await h.state.setRelay(1, true), isFalse);
      await pumpEventQueue();
      expect(h.directMock.count('POST', '/api/relay'), 0);
      expect(failures, isNotEmpty);
    });

    test('ev başına adres: setHost aktif evin adresini ayrıca saklar; ev değişince o evin adresi yüklenir', () async {
      final h = await readyHarness(configure: (h) {
        h.cloud.homes = <HomeModel>[testHome(), testHome(id: kHomeB, name: 'Ev B', topic: 'h_b')];
        h.cloud.endpoints[kHomeB] = testEndpoints(homeId: kHomeB, deviceUuid: uidB);
        h.cloud.devicesByHome[kHomeB] = <DeviceInfo>[
          const DeviceInfo(deviceUuid: uidB, name: 'Pano B', online: true, firmware: '1.3.0'),
        ];
      });
      addTearDown(h.dispose);
      h.directMock.on('GET', '/api/status', (r) => jsonResponse(lanStatus(device: r.url.host == '192.168.1.40' ? uidB : uidA)));
      await h.state.setMode(AppMode.direct);
      await h.state.setHost('192.168.1.30');
      await h.state.selectHome(h.state.homeById(kHomeB)!);
      await h.state.setHost('192.168.1.40');
      await pumpEventQueue();
      expect(h.state.status?.uid, uidB);

      await h.state.selectHome(h.state.homeById(kHomeA)!);
      await pumpEventQueue();
      expect(h.state.host, '192.168.1.30');
      expect(h.state.status?.uid, uidA);
    });
  });

  group('bireysel-5: girişsiz yerel kip', () {
    testWidgets('anahtarsız girişsiz kullanıcı adres/anahtar kartını görür (açıklamayla)', (tester) async {
      final h = (await tester.runAsync(() async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final h = StateHarness();
        h.state
          ..setModeForTesting(AppMode.direct)
          ..setAuthStatusForTesting(AuthStatus.unauthenticated);
        return h;
      }))!;
      addTearDown(h.dispose);
      expect(h.state.hasLocalKey, isFalse);
      await pumpApp(tester, state: h.state, child: const DeviceSettingsPage(), size: const Size(800, 4200));
      expect(find.byKey(const Key('card_host')), findsOneWidget);
      expect(find.byKey(const Key('field_local_key')), findsOneWidget);
      expect(
        find.text('Cihaz anahtarı etikette yazmaz; hesabınızla giriş yaparsanız (ev sahibi/üye) anahtar otomatik alınır.'),
        findsOneWidget,
      );
    });

    test('elle girilen anahtar LAN panosunun kimliğiyle saklanır; yeniden açılışta geri yüklenir', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'saved_app_mode': 'direct',
        'saved_esp_host': '192.168.1.30',
      });
      final memory = InMemorySecureStore();
      final h = StateHarness(autoInit: true, storage: FakeStorage(memory: memory));
      h.directMock.on('GET', '/api/status', (r) {
        return keyHeader(r) == null ? jsonResponse(restricted()) : jsonResponse(lanStatus());
      });
      await h.state.ready;
      await pumpEventQueue(times: 40);
      expect(h.state.isAuthenticated, isFalse);
      expect(h.state.hasLocalKey, isFalse);

      await h.state.setLocalKey('devicekey-1234');
      await pumpEventQueue(times: 40);
      expect(h.state.hasLocalKey, isTrue);
      expect(await h.storage.getLocalKey(uidA), 'devicekey-1234');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('saved_lan_device_uuid'), uidA);
      h.dispose();

      // Yeniden açılış (aynı depo + tercihler).
      final again = StateHarness(autoInit: true, storage: FakeStorage(memory: memory));
      addTearDown(again.dispose);
      again.directMock.on('GET', '/api/status', (r) => jsonResponse(lanStatus()));
      await again.state.ready;
      await pumpEventQueue(times: 40);
      expect(again.state.hasLocalKey, isTrue);
      expect(again.state.status, isNotNull);
    });
  });
}
