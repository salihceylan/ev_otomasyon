import 'dart:async';
import 'dart:convert';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/support.dart';

/// PF-03 / PF-39 / PF-35 (WP-STATE, S3): ağ-öncelikli soğuk açılış yerine önbellek-önce (SWR).
///
/// * Saklı ev listesi varsa oturum HEMEN `authenticated` olur, ilk ev seçilir (uç noktalar + canlı kanal),
///   ev listesi arka planda sunucuyla uzlaşır. `homesFromCache` YALNIZ ağ hatasında true olur (yanlış
///   "Çevrimdışısınız" şeridi çıkmaz).
/// * `selectHome` REST yenilemesi ile canlı kanalı (MQTT) eşzamanlı başlatır; ön plana dönüş ev listesi + REST + MQTT'yi
///   eşzamanlı yapar.
/// * `login()` ev listesini bekler ama ilk evin REST yığınını/MQTT'yi beklemez (giriş diyalogları açık kalmaz).
/// * Ev listesi önbelleği içerik değişmedikçe yeniden yazılmaz.
void main() {
  UserModel user(String id) => UserModel(id: id, email: '$id@example.test', fullName: 'Kullanıcı $id', role: 'user');

  Future<void> settle() => pumpEventQueue();

  /// Saklı oturum + (verilirse) ev önbelleği.
  Future<FakeStorage> storedSession({List<HomeModel>? cache, String cacheUser = 'user-1'}) async {
    final storage = FakeStorage();
    storage.memory.data
      ..['ahbu_auth_token'] = 'stored-access'
      ..['ahbu_refresh_token'] = 'stored-refresh'
      ..['ahbu_current_user'] = jsonEncode(user('user-1').toJson());
    if (cache != null) await storage.saveHomesCache(cacheUser, cache);
    return storage;
  }

  FakeCloudApi cloudWith({List<HomeModel>? homes}) => FakeCloudApi()
    ..homes = homes ?? <HomeModel>[testHome()]
    ..endpoints[kHomeA] = testEndpoints()
    ..devicesByHome[kHomeA] = <DeviceInfo>[
      const DeviceInfo(deviceUuid: 'AHBU-S3-TEST01', name: 'Pano', online: true, firmware: '1.1.0'),
    ];

  StateHarness start(FakeStorage storage, FakeCloudApi cloud) {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    return StateHarness(autoInit: true, storage: storage, cloud: cloud);
  }

  group('önbellek-önce açılış (PF-03)', () {
    test('ev listesi sunucudan GELMEDEN pano açılır: authenticated, ilk ev seçili, uç noktalar yüklü, homesLoading true', () async {
      final cloud = cloudWith()..fetchHomesGate = Completer<void>(); // ev listesi isteği hiç dönmüyor
      final h = start(await storedSession(cache: <HomeModel>[testHome()]), cloud);
      addTearDown(h.dispose);

      await h.clock.elapse(const Duration(seconds: 1));

      expect(h.state.authStatus, AuthStatus.authenticated, reason: 'eskiden: fetchHomes beklenirdi (kara delikli ağda 30 sn)');
      expect(h.state.homes.map((e) => e.id), <String>[kHomeA]);
      expect(h.state.activeHome?.id, kHomeA);
      expect(h.state.homesLoading, isTrue, reason: 'sunucu uzlaşması sürüyor');
      expect(h.state.homesLoaded, isFalse);
      expect(h.state.homesFromCache, isFalse, reason: 'SWR penceresinde false: çevrimiçi kullanıcıya "Çevrimdışısınız" şeridi çıkmaz');
      expect(h.state.homesError, isNull);
      expect(cloud.count('fetchEndpoints'), greaterThanOrEqualTo(1), reason: 'ilk evin REST yığını ev listesini beklemeden başladı');
      expect(h.state.endpointsLoaded, isTrue);
      expect(h.mqtt.startCount, 1, reason: 'canlı kanal da ev listesini beklemeden başladı');
      expect(h.state.capabilities.isOwner, isTrue);
    });

    test('kapı açılınca sunucuyla uzlaşır: homesLoaded true, homesLoading false, homesFromCache false; aynı liste yeniden yazılmaz', () async {
      final storage = await storedSession(cache: <HomeModel>[testHome()]);
      final cloud = cloudWith()..fetchHomesGate = Completer<void>();
      final h = start(storage, cloud);
      addTearDown(h.dispose);
      await h.clock.elapse(const Duration(seconds: 1));
      final writes = storage.memory.writeCountFor('ahbu_homes_cache');

      cloud.fetchHomesGate!.complete();
      await settle();

      expect(h.state.homesLoaded, isTrue);
      expect(h.state.homesLoading, isFalse);
      expect(h.state.homesFromCache, isFalse);
      expect(h.state.activeHome?.id, kHomeA);
      expect(storage.memory.writeCountFor('ahbu_homes_cache'), writes, reason: 'sunucu listesi önbellekle aynı: yeniden yazılmaz (PF-35)');
    });

    test('sunucuda rol değişmişse (owner -> resident) uzlaşma önbellekteki rolü DÜZELTİR', () async {
      final cloud = cloudWith(homes: <HomeModel>[testHome(role: 'resident')])..fetchHomesGate = Completer<void>();
      final h = start(await storedSession(cache: <HomeModel>[testHome(role: 'owner')]), cloud);
      addTearDown(h.dispose);
      await h.clock.elapse(const Duration(seconds: 1));
      expect(h.state.capabilities.isOwner, isTrue, reason: 'kısa süre önbellekteki rol görünür');

      cloud.fetchHomesGate!.complete();
      await settle();

      expect(h.state.activeHome?.role, 'resident');
      expect(h.state.capabilities.isOwner, isFalse);
      expect(h.state.capabilities.isResident, isTrue);
      expect(h.state.homes.single.role, 'resident');
    });

    test('sunucu evi artık listelemiyorsa (erişim kaybı) ev bağlamı kapanır; aktif ev yok', () async {
      final cloud = cloudWith(homes: <HomeModel>[])..fetchHomesGate = Completer<void>();
      final h = start(await storedSession(cache: <HomeModel>[testHome()]), cloud);
      addTearDown(h.dispose);
      await h.clock.elapse(const Duration(seconds: 1));
      expect(h.state.activeHome?.id, kHomeA);

      cloud.fetchHomesGate!.complete();
      await settle();

      expect(h.state.homesLoaded, isTrue);
      expect(h.state.homes, isEmpty);
      expect(h.state.activeHome, isNull);
      expect(h.state.cloudEndpoints, isEmpty);
    });

    test('oturum önbellekli açılışta düşerse (401 olayı) eski ev listesi geç gelse bile oturum geri açılmaz', () async {
      final storage = await storedSession(cache: <HomeModel>[testHome()]);
      final cloud = cloudWith()..fetchHomesGate = Completer<void>();
      final h = start(storage, cloud);
      addTearDown(h.dispose);
      await h.clock.elapse(const Duration(seconds: 1));
      expect(h.state.authStatus, AuthStatus.authenticated);

      cloud.onSessionExpired?.call(SessionEndReason.refreshRejected); // refresh reddedildi: oturum sona erdi
      await settle();
      expect(h.state.authStatus, AuthStatus.unauthenticated);

      cloud.fetchHomesGate!.complete(); // eski oturumun ev listesi şimdi döndü
      await settle();

      expect(h.state.authStatus, AuthStatus.unauthenticated);
      expect(h.state.homes, isEmpty);
      expect(h.state.activeHome, isNull);
      expect(h.state.currentUser, isNull);
      expect(storage.isEmpty, isTrue, reason: 'oturum bitti: depo temiz (önbellek dahil)');
    });

    test('çevrimdışı varyant (ağ hatası): homesFromCache true + homesError dolu; oturum açık, ilk ev seçili', () async {
      final cloud = cloudWith()..fetchHomesError = ApiException.network();
      final h = start(await storedSession(cache: <HomeModel>[testHome()]), cloud);
      addTearDown(h.dispose);

      await h.state.ready;
      await settle();

      expect(h.state.authStatus, AuthStatus.authenticated);
      expect(h.state.homesFromCache, isTrue);
      expect(h.state.homesError, isNotNull);
      expect(h.state.homesLoaded, isFalse);
      expect(h.state.homes.map((e) => e.id), <String>[kHomeA]);
      expect(h.state.activeHome?.id, kHomeA);
    });

    test('önbellek BOŞSA ağ-öncelikli akış aynen: ev listesi gelene kadar "checking"', () async {
      final cloud = cloudWith()..fetchHomesGate = Completer<void>();
      final h = start(await storedSession(), cloud);
      addTearDown(h.dispose);

      await h.clock.elapse(const Duration(seconds: 1));
      expect(h.state.authStatus, AuthStatus.checking);
      expect(cloud.count('fetchEndpoints'), 0);

      cloud.fetchHomesGate!.complete();
      await h.state.ready;
      await settle();
      expect(h.state.authStatus, AuthStatus.authenticated);
      expect(h.state.homesLoaded, isTrue);
      expect(h.state.homesFromCache, isFalse);
      expect(h.state.activeHome?.id, kHomeA);
    });

    test('başka kullanıcının önbelleği KULLANILMAZ (ağ-öncelikli akış)', () async {
      final cloud = cloudWith()..fetchHomesGate = Completer<void>();
      final h = start(await storedSession(cache: <HomeModel>[testHome()], cacheUser: 'baska-kullanici'), cloud);
      addTearDown(h.dispose);

      await h.clock.elapse(const Duration(seconds: 1));

      expect(h.state.authStatus, AuthStatus.checking);
      expect(h.state.homes, isEmpty);
    });

    test('önbellek okuma hatası: storageError + ağ-öncelikli akışa dönülür (oturum yine açılır)', () async {
      final storage = await storedSession(cache: <HomeModel>[testHome()]);
      storage.memory.failReadKeys.add('ahbu_homes_cache');
      final h = start(storage, cloudWith());
      addTearDown(h.dispose);

      await h.state.ready;
      await settle();

      expect(h.state.storageError, isNotNull);
      expect(h.state.authStatus, AuthStatus.authenticated);
      expect(h.state.homesLoaded, isTrue, reason: 'ev listesi sunucudan alındı');
      expect(h.state.activeHome?.id, kHomeA);
    });

    test('biyometrik kilit önce kalır: doğrulanmadan önbellek bile gösterilmez; doğrulayınca önbellek-önce açılır', () async {
      final storage = await storedSession(cache: <HomeModel>[testHome()]);
      storage.memory.data['ahbu_biometric_enabled'] = 'true';
      final cloud = cloudWith()..fetchHomesGate = Completer<void>();
      final biometric = FakeBiometric(supported: true)..pending = Completer<bool>();
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final h = StateHarness(autoInit: true, storage: storage, cloud: cloud, biometric: biometric);
      addTearDown(h.dispose);
      await settle();

      expect(h.state.authStatus, AuthStatus.checking);
      expect(h.state.homes, isEmpty, reason: 'kilitliyken ev verisi yüklenmez');
      expect(cloud.calls, isEmpty);

      biometric.pending!.complete(true);
      await h.clock.elapse(const Duration(seconds: 1));

      expect(h.state.authStatus, AuthStatus.authenticated, reason: 'kilit açıldı: ev listesi sunucudan beklenmeden pano açıldı');
      expect(h.state.activeHome?.id, kHomeA);
    });
  });

  group('eşzamanlı başlatma (selectHome / ön plana dönüş / mod değişimi)', () {
    test('selectHome: REST yığını (uç noktalar) kapıda beklerken canlı kanal (MQTT) BAŞLAR', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final h = StateHarness();
      addTearDown(h.dispose);
      h.cloud
        ..homes = <HomeModel>[testHome()]
        ..endpoints[kHomeA] = testEndpoints();
      h.state
        ..setCurrentUserForTesting(user('user-1'))
        ..setAuthStatusForTesting(AuthStatus.authenticated);
      await h.state.fetchHomes(autoSelect: false);
      expect(h.mqtt.startCount, 0);
      h.cloud.fetchEndpointsGate = Completer<void>();

      final select = h.state.selectHome(h.state.homeById(kHomeA)!);
      await settle();

      expect(h.mqtt.startCount, 1, reason: 'eskiden: refresh() bitmeden _startRealtime başlamazdı');
      expect(h.state.endpointsLoaded, isFalse);
      h.cloud.fetchEndpointsGate!.complete();
      await select;
      expect(h.state.endpointsLoaded, isTrue);
      expect(h.mqtt.startCount, 1);
    });

    test('canlı durum REST yanıtından ÖNCE gelirse REST üstüne uygulanır (yarış güvenli)', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final h = StateHarness();
      addTearDown(h.dispose);
      h.cloud
        ..homes = <HomeModel>[testHome()]
        ..endpoints[kHomeA] = testEndpoints();
      h.state
        ..setCurrentUserForTesting(user('user-1'))
        ..setAuthStatusForTesting(AuthStatus.authenticated);
      await h.state.fetchHomes(autoSelect: false);
      h.cloud.fetchEndpointsGate = Completer<void>();

      final select = h.state.selectHome(h.state.homeById(kHomeA)!);
      await settle();
      h.clock.advance(const Duration(milliseconds: 50));
      h.mqtt.emitStateJson(stateJson(relays: <int, bool>{1: true})); // röle 1 AÇIK (REST henüz dönmedi)
      await settle();
      h.clock.advance(const Duration(milliseconds: 50));
      h.cloud.fetchEndpointsGate!.complete(); // REST: röle 1 kapalı (eski)
      await select;

      expect(ep(h.state, 1).currentState, isTrue, reason: 'daha yeni canlı durum REST\'in bayat değerini ezdi');
    });

    test('ön plana dönüş: ev listesi + REST + MQTT EŞZAMANLI başlar (ev listesi kapıda beklerken bile)', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      final starts = h.mqtt.startCount;
      final fetches = h.cloud.count('fetchHomes');
      final endpoints = h.cloud.count('fetchEndpoints');
      h.state.handleLifecycleState(AppLifecycleState.paused);
      await settle();
      h.cloud.fetchHomesGate = Completer<void>();

      h.state.handleLifecycleState(AppLifecycleState.resumed);
      await settle();

      expect(h.cloud.count('fetchHomes'), fetches + 1);
      expect(h.cloud.count('fetchEndpoints'), endpoints + 1, reason: 'eskiden: ev listesi dönmeden REST başlamazdı');
      expect(h.mqtt.startCount, starts + 1, reason: 'eskiden: MQTT en sonda başlardı');
      h.cloud.fetchHomesGate!.complete();
      await settle();
      expect(h.state.activeHome?.id, kHomeA);
    });

    test('doğrudan moddan buluta dönüş: REST yenilemesi ve MQTT eşzamanlı başlar', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      expect(await h.state.setMode(AppMode.direct), isTrue);
      final starts = h.mqtt.startCount;
      final fetches = h.cloud.count('fetchHomes');
      final endpoints = h.cloud.count('fetchEndpoints');
      h.cloud.fetchEndpointsGate = Completer<void>();

      final back = h.state.setMode(AppMode.cloud);
      await settle();

      expect(h.mqtt.startCount, starts + 1, reason: 'canlı kanal REST yığınını beklemeden başladı');
      expect(h.cloud.count('fetchEndpoints'), endpoints + 1);
      expect(h.cloud.count('fetchHomes'), fetches, reason: 'ev listesi burada yenilenmez (eski davranış korunur)');
      h.cloud.fetchEndpointsGate!.complete();
      expect(await back, isTrue);
      expect(h.state.endpointsLoaded, isTrue);
      expect(h.state.activeHome?.id, kHomeA);
    });
  });

  group('giriş sonrası (PF-39)', () {
    test('login(): ev listesini (bir tur) bekler ama ilk evin REST yığınını ve MQTT\'yi BEKLEMEZ', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final h = StateHarness();
      addTearDown(h.dispose);
      h.cloud
        ..homes = <HomeModel>[testHome()]
        ..endpoints[kHomeA] = testEndpoints()
        ..fetchHomesGate = Completer<void>();

      var done = false;
      unawaited(h.state.login('a@b.c', 'parola-1234').then((_) => done = true));
      await settle();
      expect(done, isFalse, reason: 'ev listesi bekleniyor');
      expect(h.state.isAuthenticated, isTrue);

      h.cloud.fetchEndpointsGate = Completer<void>(); // REST yığını takılı kalsın
      h.cloud.fetchHomesGate!.complete();
      await settle();

      expect(done, isTrue, reason: 'eskiden: otomatik ev seçimi + REST + MQTT bitene kadar giriş diyalogları açık kalırdı');
      expect(h.state.homesLoaded, isTrue);
      expect(h.state.activeHome?.id, kHomeA, reason: 'ilk ev arka planda seçildi');
      expect(h.cloud.count('fetchEndpoints'), 1);
      expect(h.mqtt.startCount, 1);
      expect(h.state.endpointsLoaded, isFalse);

      h.cloud.fetchEndpointsGate!.complete();
      await settle();
      expect(h.state.endpointsLoaded, isTrue);
    });

    test('login sonrası settle() ile ilk ev seçili ve uç noktalar yüklüdür (mevcut test kalıbı)', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final h = StateHarness();
      addTearDown(h.dispose);
      h.cloud
        ..homes = <HomeModel>[testHome()]
        ..endpoints[kHomeA] = testEndpoints();

      expect(await h.state.login('a@b.c', 'parola-1234'), isTrue);
      await settle();

      expect(h.state.activeHome?.id, kHomeA);
      expect(h.state.endpointsLoaded, isTrue);
      expect(h.state.cloudEndpoints, isNotEmpty);
    });

    test('girişten hemen sonra çıkış: geç dönen ev seçimi çıkış yapılmış oturuma ev BAĞLAMAZ', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final h = StateHarness();
      addTearDown(h.dispose);
      h.cloud
        ..homes = <HomeModel>[testHome()]
        ..endpoints[kHomeA] = testEndpoints();

      expect(await h.state.login('a@b.c', 'parola-1234'), isTrue);
      await h.state.logout(); // ilk ev seçimi (arka plan) henüz bitmeden
      await settle();

      expect(h.state.authStatus, AuthStatus.unauthenticated);
      expect(h.state.activeHome, isNull);
      expect(h.state.homes, isEmpty);
    });
  });

  group('ev listesi önbelleği (PF-35)', () {
    test('içerik değişmedikçe yeniden yazılmaz; liste değişince yazılır', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      await settle();
      const key = 'ahbu_homes_cache';
      final first = h.storage.memory.writeCountFor(key);
      expect(first, 1, reason: 'ilk başarılı fetchHomes önbelleği yazar');

      await h.state.fetchHomes(autoSelect: false);
      await h.state.fetchHomes(autoSelect: false);
      await settle();
      expect(h.storage.memory.writeCountFor(key), first, reason: 'aynı liste: yazma yok (güvenli depo yazımı pahalı)');

      h.cloud.homes = <HomeModel>[testHome(), testHome(id: kHomeB, name: 'Ev B', topic: 'h_b')];
      await h.state.fetchHomes(autoSelect: false);
      await settle();
      expect(h.storage.memory.writeCountFor(key), first + 1, reason: 'liste değişti');
      expect((await h.storage.loadHomesCache('user-1')).map((e) => e.id), <String>[kHomeA, kHomeB]);
    });

    test('yazma hatası sonrası aynı liste yeniden denenir (özet yalnız başarılı yazımda kaydedilir)', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      await settle();
      const key = 'ahbu_homes_cache';
      h.cloud.homes = <HomeModel>[testHome(), testHome(id: kHomeB, name: 'Ev B', topic: 'h_b')];
      h.storage.memory.failWrites = true;
      await h.state.fetchHomes(autoSelect: false);
      await settle();
      final failed = h.storage.memory.writeCountFor(key);

      h.storage.memory.failWrites = false;
      await h.state.fetchHomes(autoSelect: false);
      await settle();

      expect(h.storage.memory.writeCountFor(key), failed + 1, reason: 'başarısız yazım "yazıldı" sayılmadı');
      expect((await h.storage.loadHomesCache('user-1')).length, 2);
    });

    test('çıkış + yeni giriş: yeni oturumun listesi (depo silindiği için) yeniden yazılır', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      await settle();
      const key = 'ahbu_homes_cache';
      await h.state.logout();
      expect(h.storage.memory.data, isNot(contains(key)));
      final before = h.storage.memory.writeCountFor(key);

      expect(await h.state.login('a@b.c', 'parola-1234'), isTrue);
      await settle();

      expect(h.storage.memory.writeCountFor(key), before + 1);
      expect(h.storage.memory.data, contains(key));
    });
  });
}
