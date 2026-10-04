import 'dart:async';
import 'dart:convert';

import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/support.dart';

/// PF-30 (WP-STATE, S2): biyometrik istem sürerken oturum değişirse (çıkış / yeni giriş) geç dönen doğrulama
/// sonucu oturumu YENİDEN AÇMAZ ve tercihi yazmaz; askıda kalan etkileşimli istem 2 dk sonra "başarısız"
/// sayılır (yaşam döngüsü ve splash kaçışı sonsuza dek kilitlenmez).
void main() {
  UserModel user(String id) => UserModel(id: id, email: '$id@example.test', fullName: 'Kullanıcı $id', role: 'user');

  Future<void> settle() => pumpEventQueue();

  /// Biyometrik kilit AÇIK saklı oturum; doğrulama [biometric].pending ile elle tamamlanır.
  StateHarness lockedStart(FakeBiometric biometric) {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final storage = FakeStorage();
    storage.memory.data
      ..['ahbu_auth_token'] = 'stored-access'
      ..['ahbu_refresh_token'] = 'stored-refresh'
      ..['ahbu_current_user'] = jsonEncode(user('user-1').toJson())
      ..['ahbu_biometric_enabled'] = 'true';
    final cloud = FakeCloudApi()
      ..homes = <HomeModel>[testHome()]
      ..endpoints[kHomeA] = testEndpoints();
    return StateHarness(autoInit: true, storage: storage, cloud: cloud, biometric: biometric);
  }

  group('istem açıkken oturum değişirse', () {
    test('çıkış sonra doğrulama BAŞARILI: oturum yeniden açılmaz (authenticated + kullanıcı yok olmaz)', () async {
      final biometric = FakeBiometric(supported: true)..pending = Completer<bool>();
      final h = lockedStart(biometric);
      addTearDown(h.dispose);
      await settle();
      expect(h.state.authStatus, AuthStatus.checking);
      expect(h.state.biometricChecking, isTrue);

      await h.state.fallbackToPasswordLogin(); // splash: "şifre ile giriş"
      expect(h.state.authStatus, AuthStatus.unauthenticated);

      biometric.pending!.complete(true); // geç gelen doğrulama
      await h.state.ready;
      await settle();

      expect(h.state.authStatus, AuthStatus.unauthenticated, reason: 'eskiden: authenticated + currentUser null (pano açılırdı)');
      expect(h.state.currentUser, isNull);
      expect(h.state.biometricChecking, isFalse);
      expect(h.cloud.calls, isNot(contains('fetchHomes')), reason: 'oturum yok: ağ başlatılmaz');
      expect(h.mqtt.startCount, 0);
    });

    test('çıkış + YENİ giriş sonra eski doğrulama başarılı: yeni oturum bozulmaz (ikinci kez başlatılmaz)', () async {
      final biometric = FakeBiometric(supported: true)..pending = Completer<bool>();
      final h = lockedStart(biometric);
      addTearDown(h.dispose);
      h.cloud.loginUser = user('user-2');
      await settle();

      await h.state.logout();
      expect(await h.state.login('a@b.c', 'parola-1234'), isTrue);
      await settle();
      final fetches = h.cloud.count('fetchHomes');
      final starts = h.mqtt.startCount;

      biometric.pending!.complete(true);
      await h.state.ready;
      await settle();

      expect(h.state.authStatus, AuthStatus.authenticated);
      expect(h.state.currentUser?.id, 'user-2');
      expect(h.cloud.count('fetchHomes'), fetches, reason: 'eski kilit açma yeni oturumu yeniden başlatmaz');
      expect(h.mqtt.startCount, starts);
    });

    test('toggleBiometric doğrulama sürerken çıkış: tercih depoya YAZILMAZ, durumda açılmaz, false döner', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.state.setBiometricForTesting(isSupported: true, isEnabled: false);
      final pending = Completer<bool>();
      h.biometric
        ..supported = true
        ..pending = pending;

      final toggle = h.state.toggleBiometric(true);
      await settle();
      await h.state.logout();
      pending.complete(true);

      expect(await toggle, isFalse, reason: 'oturum değişti: doğrulama başka oturuma aitti');
      await settle();
      expect(h.state.isBiometricEnabled, isFalse);
      expect(h.storage.memory.data, isNot(contains('ahbu_biometric_enabled')),
          reason: 'çıkıştan sonra tercih yazımı: eski kodda epoch await\'ten SONRA okunuyordu');
    });

    test('toggleBiometric oturum DEĞİŞMEDEN tamamlanırsa tercih yazılır (kontrol: kilit boş geçmesin)', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.state.setBiometricForTesting(isSupported: true, isEnabled: false);
      h.biometric.supported = true;

      expect(await h.state.toggleBiometric(true), isTrue);
      await settle();

      expect(h.state.isBiometricEnabled, isTrue);
      expect(h.storage.memory.data['ahbu_biometric_enabled'], 'true');
    });
  });

  group('askıda kalan etkileşimli istem (2 dk bekçisi)', () {
    test('3 dk sonra: biometricChecking false, biometricFailed true; açılış (ready) tamamlanır; kilitli kalır', () async {
      final biometric = FakeBiometric(supported: true)..pending = Completer<bool>();
      final h = lockedStart(biometric);
      addTearDown(h.dispose);
      var readyDone = false;
      unawaited(h.state.ready.then((_) => readyDone = true));
      await settle();
      expect(h.state.biometricChecking, isTrue);
      expect(readyDone, isFalse);

      await h.clock.elapse(const Duration(minutes: 1, seconds: 50));
      expect(h.state.biometricChecking, isTrue, reason: '2 dk dolmadan istem hâlâ kullanıcı bekliyor');

      await h.clock.elapse(const Duration(minutes: 1, seconds: 10));

      expect(h.state.biometricChecking, isFalse);
      expect(h.state.biometricFailed, isTrue);
      expect(h.state.authStatus, AuthStatus.checking, reason: 'doğrulanmadı: kilit açılmadı');
      expect(readyDone, isTrue);
      expect(h.cloud.calls, isEmpty);
      expect(h.mqtt.startCount, 0);
    });

    test('bekçi sonrası yaşam döngüsü yeniden işlenir (askıdaki istem artık engellemez)', () async {
      final biometric = FakeBiometric(supported: true)..pending = Completer<bool>();
      final h = lockedStart(biometric);
      addTearDown(h.dispose);
      await settle();

      h.state.handleLifecycleState(AppLifecycleState.paused);
      expect(h.state.isInBackground, isFalse, reason: 'istem sürerken yaşam döngüsü yok sayılır (mevcut davranış)');

      await h.clock.elapse(const Duration(minutes: 3));
      h.state.handleLifecycleState(AppLifecycleState.paused);

      expect(h.state.isInBackground, isTrue);
      h.state.handleLifecycleState(AppLifecycleState.resumed);
      expect(h.state.authStatus, AuthStatus.checking, reason: 'kilitliyken ön plana dönüş oturumu açmaz');
    });

    test('bekçiden SONRA gelen eski doğrulama sonucu yok sayılır; yeniden deneme çalışır ve oturumu başlatır', () async {
      final biometric = FakeBiometric(supported: true)..pending = Completer<bool>();
      final h = lockedStart(biometric);
      addTearDown(h.dispose);
      await settle();
      await h.clock.elapse(const Duration(minutes: 3));
      expect(h.state.biometricFailed, isTrue);

      biometric.pending!.complete(true); // zaman aşımından sonra dönen eski istem
      await settle();
      expect(h.state.authStatus, AuthStatus.checking, reason: 'bekçi "başarısız" dedi; geç sonuç oturumu açmaz');
      expect(h.cloud.calls, isEmpty);

      biometric.pending = null; // yeni istem hemen döner
      expect(await h.state.retryBiometricAuth(), isTrue);
      await settle();
      expect(h.state.authStatus, AuthStatus.authenticated);
      expect(h.state.biometricFailed, isFalse);
      expect(h.state.activeHome?.id, kHomeA);
    });

    test('istem 2 dk içinde tamamlanırsa bekçi etkisizdir (zamanlayıcı iptal): 5 dk sonra hâlâ açık oturum', () async {
      final biometric = FakeBiometric(supported: true)..pending = Completer<bool>();
      final h = lockedStart(biometric);
      addTearDown(h.dispose);
      await settle();

      await h.clock.elapse(const Duration(seconds: 30));
      biometric.pending!.complete(true);
      await h.state.ready;
      await settle();
      expect(h.state.authStatus, AuthStatus.authenticated);

      await h.clock.elapse(const Duration(minutes: 5));
      expect(h.state.authStatus, AuthStatus.authenticated);
      expect(h.state.biometricFailed, isFalse);
    });
  });
}
