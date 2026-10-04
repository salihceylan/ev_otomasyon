import 'dart:async';
import 'dart:convert';

import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/support.dart';

/// PF-02 (durum yarısı) / PF-13 / PF-29 (WP-STATE, S2): açılışta platform kanalı (güvenli depo, biyometrik
/// sonda) askıda kalsa bile `AutomationState` kilitlenmez; bağımsız okumalar paraleldir; geç dönen okuma
/// çıkış sonrası eski oturumu yeniden kurmaz; biyometrik kilit sonda zaman aşımında AÇIK kalır.
void main() {
  UserModel user(String id) => UserModel(id: id, email: '$id@example.test', fullName: 'Kullanıcı $id', role: 'user');

  /// Saklı oturum (belirteçler + kullanıcı); [biometric] `true` ise biyometrik kilit bayrağı da açık.
  InMemorySecureStore storedSession({bool biometric = false}) {
    final store = InMemorySecureStore();
    store.data
      ..['ahbu_auth_token'] = 'stored-access'
      ..['ahbu_refresh_token'] = 'stored-refresh'
      ..['ahbu_current_user'] = jsonEncode(user('user-1').toJson());
    if (biometric) store.data['ahbu_biometric_enabled'] = 'true';
    return store;
  }

  StateHarness start(InMemorySecureStore store, {FakeBiometric? biometric}) {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final cloud = FakeCloudApi()
      ..homes = <HomeModel>[testHome()]
      ..endpoints[kHomeA] = testEndpoints();
    return StateHarness(autoInit: true, storage: FakeStorage(memory: store), cloud: cloud, biometric: biometric);
  }

  group('takılan depo okuması (PF-02/PF-13)', () {
    test('15 sn içinde "checking" biter: storageError görünür, ready tamamlanır, belirteç SİLİNMEZ', () async {
      final store = storedSession()..hangReads = Completer<void>();
      final h = start(store);
      addTearDown(h.dispose);
      var readyDone = false;
      unawaited(h.state.ready.then((_) => readyDone = true));
      await pumpEventQueue();
      expect(h.state.authStatus, AuthStatus.checking);

      await h.clock.elapse(const Duration(seconds: 15));

      expect(h.state.authStatus, AuthStatus.unauthenticated);
      expect(h.state.storageError, isNotNull);
      expect(readyDone, isTrue);
      expect(h.cloud.calls, isEmpty);
      expect(store.data, contains('ahbu_auth_token'), reason: 'zaman aşımı "oturum yok" değildir: belirteç silinmez');

      store.hangReads!.complete(); // gecikmiş okumalar sonradan dönse bile yutulur
      await pumpEventQueue();
      expect(h.state.authStatus, AuthStatus.unauthenticated);
    });

    test('okumalar PARALEL: hepsi ilk 7 sn içinde (6 sn sınırı + pay) bitirir (eskiden ardışık: 12 sn)', () async {
      final store = storedSession()..hangReads = Completer<void>();
      final h = start(store);
      addTearDown(h.dispose);

      await h.clock.elapse(const Duration(seconds: 7));

      expect(h.state.authStatus, AuthStatus.unauthenticated, reason: 'beş bağımsız okuma tek 6 sn sınırında birlikte düştü');
      expect(h.state.storageError, isNotNull);
    });

    test('beş bağımsız okuma EŞZAMANLI başlar (kapı kapalıyken startedReads == 5)', () async {
      final store = storedSession()..readGate = Completer<void>();
      final h = start(store);
      addTearDown(h.dispose);
      await pumpEventQueue();

      expect(store.startedReads, 5, reason: 'belirteç + yenileme + kullanıcı + servis oturumu + biyometrik bayrak');
      expect(h.state.authStatus, AuthStatus.checking);

      store.readGate!.complete();
      await h.state.ready;
      await pumpEventQueue();
      expect(h.state.authStatus, AuthStatus.authenticated);
      expect(h.state.currentUser?.id, 'user-1');
    });

    test('dört oturum okumasından BİRİ hatalıysa oturum yok + storageError (kısmi oturum kurulmaz)', () async {
      final store = storedSession()..failReadKeys.add('ahbu_current_user');
      final h = start(store);
      addTearDown(h.dispose);
      await h.state.ready;
      await pumpEventQueue();

      expect(h.state.authStatus, AuthStatus.unauthenticated);
      expect(h.state.storageError, isNotNull);
      expect(h.cloud.hasSession, isFalse, reason: 'belirteç okunabilse de kullanıcı okunamadı: yarım oturum kurulmaz');
      expect(h.cloud.calls, isEmpty);
      expect(store.data, contains('ahbu_auth_token'), reason: 'geçici okuma hatası saklı belirteçleri SİLMEZ');
    });

    test('takılan toplu silme: logout() 10 sn içinde biter (depo çağrısı sınırlı), storageError görünür', () async {
      final store = storedSession();
      final h = start(store);
      addTearDown(h.dispose);
      await h.state.ready;
      await pumpEventQueue();
      expect(h.state.authStatus, AuthStatus.authenticated);
      store.hangDeleteAll = Completer<void>();

      var done = false;
      unawaited(h.state.logout().then((_) => done = true));
      await h.clock.elapse(const Duration(seconds: 10));

      expect(done, isTrue);
      expect(h.state.authStatus, AuthStatus.unauthenticated);
      expect(h.state.storageError, isNotNull);
    });
  });

  group('geç dönen okuma oturumu geri DÖNDÜRMEZ (PF-29)', () {
    test('çıkıştan sonra gelen okuma sonucu eski oturumu yeniden kurmaz', () async {
      final store = storedSession()..readGate = Completer<void>();
      final h = start(store);
      addTearDown(h.dispose);
      await pumpEventQueue();
      expect(h.state.authStatus, AuthStatus.checking);

      await h.state.logout(); // splash kaçışı: şifre ile girişe düş
      expect(h.state.authStatus, AuthStatus.unauthenticated);
      store.readGate!.complete(); // platform okumayı bitirdi, yanıt GEÇ döndü (6 sn dolmadan)
      await h.state.ready;
      await pumpEventQueue();

      expect(h.state.authStatus, AuthStatus.unauthenticated);
      expect(h.state.currentUser, isNull);
      expect(h.cloud.authToken, isNull);
      expect(h.cloud.calls, isEmpty, reason: 'geç dönen okuma ağ çağrısı başlatmamalı');
    });

    test('çıkış + yeni giriş sürerken geç dönen okuma yeni oturumun belirteçlerini EZMEZ', () async {
      final store = storedSession()..readGate = Completer<void>();
      final h = start(store);
      addTearDown(h.dispose);
      h.cloud.loginUser = user('user-2');
      await pumpEventQueue();

      await h.state.logout();
      // Yeni giriş (kendi depo okumaları da aynı kapıda bekler); belirteci API istemcisine hemen yazılır.
      final login = h.state.login('a@b.c', 'parola-1234');
      await pumpEventQueue();
      expect(h.cloud.authToken, 'access-1');

      store.readGate!.complete(); // eski oturumun okuması şimdi döndü
      expect(await login, isTrue);
      await h.state.ready;
      await pumpEventQueue();

      expect(h.cloud.authToken, 'access-1', reason: 'yeni oturumun belirteci eski saklı belirteçle değişmedi');
      expect(h.state.currentUser?.id, 'user-2');
      expect(h.state.authStatus, AuthStatus.authenticated);
      expect(await h.storage.getAuthToken(), 'access-1');
    });

    test('okumalar ZAMAN AŞIMINA uğradıktan sonra (15 sn) çıkış + giriş: kapı sonradan açılınca geç okuma yok sayılır', () async {
      final store = storedSession()..readGate = Completer<void>();
      final h = start(store);
      addTearDown(h.dispose);
      h.cloud.loginUser = user('user-2');

      await h.clock.elapse(const Duration(seconds: 15));
      expect(h.state.authStatus, AuthStatus.unauthenticated, reason: 'okumalar 6 sn sınırında düştü');
      expect(h.state.storageError, isNotNull);

      await h.state.logout();
      var loggedIn = false;
      unawaited(h.state.login('a@b.c', 'parola-1234').then((_) => loggedIn = true)); // kendi depo okuması da kapıda bekler
      await h.clock.elapse(const Duration(seconds: 10));
      expect(loggedIn, isTrue, reason: 'giriş, takılan depo okumasının 6 sn sınırından sonra sürer');
      expect(h.cloud.authToken, 'access-1');

      store.readGate!.complete(); // eski (zaman aşımına uğramış) okumalar şimdi döndü
      await pumpEventQueue();

      expect(h.cloud.authToken, 'access-1', reason: 'yeni oturumun belirteci kalır');
      expect(h.state.currentUser?.id, 'user-2');
      expect(h.state.authStatus, AuthStatus.authenticated);
    });

    test('dispose sırasında süren açılış, dispose sonrası ağ/MQTT başlatmaz', () async {
      final store = storedSession()..readGate = Completer<void>();
      final h = start(store);
      await pumpEventQueue();

      h.dispose();
      store.readGate!.complete();
      await pumpEventQueue();

      expect(h.cloud.calls, isEmpty);
      expect(h.mqtt.startCount, 0);
    });
  });

  group('biyometrik sonda (PF-02/PF-13)', () {
    test('oturum YOKKEN biyometrik sonda çalışmaz (açılış platform kanalına gereksiz gitmez)', () async {
      final h = start(InMemorySecureStore());
      addTearDown(h.dispose);
      await h.state.ready;

      expect(h.state.authStatus, AuthStatus.unauthenticated);
      expect(h.biometric.supportedCalls, 0);
    });

    test('oturum VARKEN sonda çalışır (kilit kararı için)', () async {
      final h = start(storedSession());
      addTearDown(h.dispose);
      await h.state.ready;
      await pumpEventQueue();

      expect(h.biometric.supportedCalls, 1);
      expect(h.state.authStatus, AuthStatus.authenticated);
    });

    test('oturum yok ama biyometrik bayrak OKUNAMADI: sonda çalışır (fail-closed karar için)', () async {
      final store = InMemorySecureStore()..failReadKeys.add('ahbu_biometric_enabled');
      final h = start(store);
      addTearDown(h.dispose);
      await h.state.ready;

      expect(h.biometric.supportedCalls, 1);
      expect(h.state.storageError, isNotNull);
      expect(h.state.authStatus, AuthStatus.unauthenticated);
    });

    test('kilit AÇIKKEN destek sondası takılırsa kilit KORUNUR (fail-closed): oturum kilitsiz başlamaz', () async {
      final biometric = FakeBiometric(supported: true, authResult: false)..hangSupported = Completer<bool>();
      final h = start(storedSession(biometric: true), biometric: biometric);
      addTearDown(h.dispose);

      await h.clock.elapse(const Duration(seconds: 15));

      expect(h.state.authStatus, AuthStatus.checking, reason: 'sonda yanıt vermedi: kilit atlanmaz');
      expect(h.state.biometricFailed, isTrue, reason: 'ekran "yeniden dene / şifre ile giriş" sunar');
      expect(h.cloud.calls, isEmpty);
      expect(h.mqtt.startCount, 0);
    });

    test('kilit KAPALIYKEN destek sondası takılırsa açılış yine de tamamlanır (kilit istenmiyor)', () async {
      final biometric = FakeBiometric(supported: true)..hangSupported = Completer<bool>();
      final h = start(storedSession(), biometric: biometric);
      addTearDown(h.dispose);

      await h.clock.elapse(const Duration(seconds: 15));

      expect(h.state.authStatus, AuthStatus.authenticated);
      expect(h.state.activeHome?.id, kHomeA);
    });

    test('giriş: biyometrik sondalar takılsa da login() 4 sn içinde biter; istem kararı bildirimden ÖNCE', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final biometric = FakeBiometric(supported: true)..hangSupported = Completer<bool>();
      final cloud = FakeCloudApi()
        ..homes = <HomeModel>[testHome()]
        ..endpoints[kHomeA] = testEndpoints();
      final h = StateHarness(biometric: biometric, cloud: cloud);
      addTearDown(h.dispose);

      var done = false;
      unawaited(h.state.login('a@b.c', 'parola-1234').then((_) => done = true));
      await h.clock.elapse(const Duration(seconds: 4));

      expect(done, isTrue);
      expect(h.state.authStatus, AuthStatus.authenticated);
      expect(h.state.shouldPromptBiometrics, isFalse, reason: 'sonda zaman aşımı: "desteklenmiyor" -> istem yok');
      expect(h.biometric.supportedCalls, 1);
    });

    test('giriş: destekleniyorsa istem kararı login() döndüğünde HAZIRDIR (DashboardPage ilk karede okur)', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final h = StateHarness(biometricSupported: true);
      addTearDown(h.dispose);
      h.cloud.homes = <HomeModel>[testHome()];

      expect(await h.state.login('a@b.c', 'parola-1234'), isTrue);

      expect(h.state.isBiometricSupported, isTrue);
      expect(h.state.biometricLabel, 'Parmak İzi');
      expect(h.state.shouldPromptBiometrics, isTrue);
    });
  });
}
