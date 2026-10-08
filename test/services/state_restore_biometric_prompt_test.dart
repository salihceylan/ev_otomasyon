import 'dart:async';
import 'dart:convert';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/support.dart';

/// WP-BIO2 (A): oturum GERİ YÜKLENİRKEN (soğuk açılış) ilk kullanım biyometrik istemi.
///
/// Giriş yolunda (`_handleAuthSuccess`) var olan "Biyometrik kullanılsın mı?" kararı artık saklı oturum geri
/// yüklenirken de verilir: cihaz destekliyor + istem daha önce gösterilmedi + biyometrik giriş kapalı ->
/// `shouldPromptBiometrics` true (DashboardPage istemi açar). Tek sefer: "Daha Sonra" / "Etkinleştir" kaydı
/// yazar ve sonraki açılışlarda istem çıkmaz. Fail-safe: servis oturumu, biyometrik kilit açık, cihaz
/// desteklemiyor (sonda zaman aşımı dahil) ya da kayıt okunamıyorsa istem YOK.
void main() {
  UserModel user(String id) => UserModel(id: id, email: '$id@example.test', fullName: 'Kullanıcı $id', role: 'user');

  Future<void> settle() => pumpEventQueue();

  /// Saklı kullanıcı oturumu. [biometricEnabled]: kilit tercihi; [promptShown]: "istem gösterildi" kaydı
  /// (`null` = kayıt yok, yani istem daha önce hiç sunulmadı).
  FakeStorage storedSession({bool biometricEnabled = false, bool? promptShown}) {
    final storage = FakeStorage();
    storage.memory.data
      ..['ahbu_auth_token'] = 'stored-access'
      ..['ahbu_refresh_token'] = 'stored-refresh'
      ..['ahbu_current_user'] = jsonEncode(user('user-1').toJson())
      ..['ahbu_biometric_enabled'] = biometricEnabled ? 'true' : 'false';
    if (promptShown != null) storage.memory.data['ahbu_biometric_prompt_shown'] = promptShown ? 'true' : 'false';
    return storage;
  }

  /// Otomatik başlatılan durum (soğuk açılış).
  StateHarness start({required FakeStorage storage, FakeBiometric? biometric, bool supported = true}) {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final cloud = FakeCloudApi()
      ..homes = <HomeModel>[testHome()]
      ..endpoints[kHomeA] = testEndpoints();
    final h = StateHarness(
      autoInit: true,
      storage: storage,
      cloud: cloud,
      biometric: biometric ?? FakeBiometric(supported: supported),
    );
    addTearDown(h.dispose);
    return h;
  }

  group('(a) ilk kullanımda istem', () {
    test('destekleniyor + istem hiç gösterilmedi + biyometrik kapalı: shouldPromptBiometrics true; oturum kilitsiz açılır', () async {
      final h = start(storage: storedSession());
      await h.state.ready;
      await settle();

      expect(h.state.authStatus, AuthStatus.authenticated);
      expect(h.state.shouldPromptBiometrics, isTrue);
      expect(h.state.isBiometricSupported, isTrue);
      expect(h.state.isBiometricEnabled, isFalse);
      expect(h.state.biometricLabel, 'Parmak İzi', reason: 'istem başlığı için etiket sondası da yapıldı');
      expect(h.biometric.authenticateCalls, 0, reason: 'istem bir öneridir: kilit açma doğrulaması istenmez');
      expect(h.state.activeHome?.id, kHomeA, reason: 'istem oturum başlatmayı geciktirmez');
      expect(await h.storage.isBiometricPromptShown(), isFalse, reason: 'karar verilmeden "gösterildi" yazılmaz');
    });

    test('karar pano açılmadan (ilk "authenticated" bildiriminden) ÖNCE hazırdır: DashboardPage ilk karede okur', () async {
      final h = start(storage: storedSession());
      bool? promptAtDashboard;
      h.state.addListener(() {
        if (promptAtDashboard == null && h.state.authStatus == AuthStatus.authenticated) {
          promptAtDashboard = h.state.shouldPromptBiometrics;
        }
      });
      await h.state.ready;
      await settle();

      expect(promptAtDashboard, isTrue, reason: 'pano ilk kurulduğunda bayrak zaten true olmalı');
    });

    test('"Daha Sonra" (dismiss): kayıt yazılır; aynı depoyla İKİNCİ soğuk açılışta istem YOK (tek sefer)', () async {
      final storage = storedSession();
      final first = start(storage: storage);
      await first.state.ready;
      await settle();
      expect(first.state.shouldPromptBiometrics, isTrue, reason: 'hazırlık');

      await first.state.dismissBiometricPrompt();
      await settle();
      expect(first.state.shouldPromptBiometrics, isFalse);
      expect(first.state.isBiometricEnabled, isFalse);
      expect(await storage.isBiometricPromptShown(), isTrue);
      first.dispose();

      final second = start(storage: storage);
      await second.state.ready;
      await settle();
      expect(second.state.authStatus, AuthStatus.authenticated);
      expect(second.state.shouldPromptBiometrics, isFalse, reason: 'bir daha sorulmaz');
    });

    test('"Evet, Etkinleştir": doğrulama + tercih yazılır; sonraki açılış KİLİTLİ başlar ve istem yoktur', () async {
      final storage = storedSession();
      final first = start(storage: storage);
      await first.state.ready;
      await settle();
      expect(first.state.shouldPromptBiometrics, isTrue, reason: 'hazırlık');

      expect(await first.state.enableBiometricWithVerification(), isTrue);
      await settle();
      expect(first.biometric.authenticateCalls, 1);
      expect(first.state.isBiometricEnabled, isTrue);
      expect(first.state.shouldPromptBiometrics, isFalse);
      expect(await storage.isBiometricEnabled(), isTrue);
      expect(await storage.isBiometricPromptShown(), isTrue);
      first.dispose();

      final biometric = FakeBiometric(supported: true)..pending = Completer<bool>();
      final second = start(storage: storage, biometric: biometric);
      await settle();
      expect(second.state.authStatus, AuthStatus.checking, reason: 'biyometrik kilit: doğrulanana kadar pano yok');
      expect(second.state.shouldPromptBiometrics, isFalse);
      expect(second.cloud.calls, isEmpty);

      biometric.pending!.complete(true);
      await second.state.ready;
      await settle();
      expect(second.state.authStatus, AuthStatus.authenticated);
      expect(second.state.shouldPromptBiometrics, isFalse, reason: 'biyometrik zaten açık: istem gerekmez');
    });
  });

  group('(b)-(e) istem gösterilmeyen durumlar', () {
    test('(b) istem daha önce gösterildiyse (kayıt true) istem yok; oturum normal açılır', () async {
      final h = start(storage: storedSession(promptShown: true));
      await h.state.ready;
      await settle();

      expect(h.state.authStatus, AuthStatus.authenticated);
      expect(h.state.shouldPromptBiometrics, isFalse);
      expect(h.state.isBiometricSupported, isTrue);
    });

    test('(c) biyometrik AÇIK: kilit var, istem yok; kilit açıldıktan sonra da istem yok (kayıt okunmaz)', () async {
      final biometric = FakeBiometric(supported: true)..pending = Completer<bool>();
      final storage = storedSession(biometricEnabled: true); // "istem gösterildi" kaydı YOK
      final h = start(storage: storage, biometric: biometric);
      await settle();

      expect(h.state.authStatus, AuthStatus.checking);
      expect(h.state.biometricChecking, isTrue);
      expect(h.state.shouldPromptBiometrics, isFalse);
      expect(storage.memory.startedReads, 5, reason: 'kilit açıkken "istem gösterildi" kaydı okunmaz (beş oturum okuması)');

      biometric.pending!.complete(true);
      await h.state.ready;
      await settle();
      expect(h.state.authStatus, AuthStatus.authenticated);
      expect(h.state.shouldPromptBiometrics, isFalse, reason: 'biyometrik zaten etkin: istem gerekmez');
      // +1 ev listesi önbelleği (oturum başlatma) ve +1 birincil panonun yerel anahtar kaydı (pano-6: anahtar depoda varsa
      // önden tazelenir); istem kaydı okunmaz.
      expect(storage.memory.startedReads, 7);
      expect(storage.memory.readCountFor('ahbu_biometric_prompt_shown'), 0, reason: 'istem kaydı okunmaz');
    });

    test('(c2) biyometrik tercihi OKUNAMADI (fail-closed kilit): kilitli başlar, istem yok', () async {
      final biometric = FakeBiometric(supported: true)..pending = Completer<bool>();
      final storage = storedSession();
      storage.memory.failReadKeys.add('ahbu_biometric_enabled');
      final h = start(storage: storage, biometric: biometric);
      await settle();

      expect(h.state.authStatus, AuthStatus.checking, reason: 'tercih okunamadı -> kilit AÇIK varsayılır');
      expect(h.state.shouldPromptBiometrics, isFalse);
      biometric.pending!.complete(true);
      await h.state.ready;
      await settle();
      expect(h.state.shouldPromptBiometrics, isFalse);
    });

    test('(d) servis PIN oturumu geri yüklenirken istem yok ve kayıt okunmaz', () async {
      final storage = FakeStorage();
      storage.memory.data
        ..['ahbu_auth_token'] = 'service-access'
        ..['ahbu_service_session'] = jsonEncode(ServiceSessionInfo(
          homeId: kHomeA,
          homeName: 'Servis Evi',
          expiresAt: kTestNow.add(const Duration(hours: 1)),
          technicianName: 'Usta',
        ).toJson());
      final h = start(storage: storage);
      await h.state.ready;
      await settle();

      expect(h.state.isServiceSession, isTrue);
      expect(h.state.authStatus, AuthStatus.authenticated);
      expect(h.state.shouldPromptBiometrics, isFalse);
      expect(storage.memory.startedReads, 5, reason: 'servis oturumunda "istem gösterildi" kaydı okunmaz');
      expect(h.biometric.authenticateCalls, 0);
    });

    test('(e) "istem gösterildi" kaydı OKUNAMIYORSA istem yok (fail-safe); oturum yine açılır', () async {
      final storage = storedSession();
      storage.memory.failReadKeys.add('ahbu_biometric_prompt_shown');
      final h = start(storage: storage);
      await h.state.ready;
      await settle();

      expect(h.state.authStatus, AuthStatus.authenticated, reason: 'kayıt oturum için kritik değil');
      expect(h.state.shouldPromptBiometrics, isFalse);
      expect(h.state.storageError, isNull, reason: 'yalnız istem kararını etkiler; kullanıcıya depo hatası gösterilmez');
      expect(h.state.activeHome?.id, kHomeA);
    });

    test('(e2) cihaz desteklemiyorsa istem yok', () async {
      final h = start(storage: storedSession(), supported: false);
      await h.state.ready;
      await settle();

      expect(h.state.authStatus, AuthStatus.authenticated);
      expect(h.state.isBiometricSupported, isFalse);
      expect(h.state.shouldPromptBiometrics, isFalse);
    });

    test('(e3) destek sondası zaman aşımı: "desteklenmiyor" sayılır -> istem yok; açılış kilitsiz tamamlanır', () async {
      final biometric = FakeBiometric(supported: true)..hangSupported = Completer<bool>();
      final h = start(storage: storedSession(), biometric: biometric);

      await h.clock.elapse(const Duration(seconds: 15));

      expect(h.state.authStatus, AuthStatus.authenticated);
      expect(h.state.shouldPromptBiometrics, isFalse, reason: 'sonda yanıt vermedi: istem açılmaz (fail-safe)');
      expect(h.state.activeHome?.id, kHomeA);
    });

    test('oturumsuz açılışta "istem gösterildi" kaydı okunmaz (yalnız beş oturum okuması) ve istem yok', () async {
      final storage = FakeStorage();
      final h = start(storage: storage);
      await h.state.ready;
      await settle();

      expect(h.state.authStatus, AuthStatus.unauthenticated);
      expect(h.state.shouldPromptBiometrics, isFalse);
      expect(storage.memory.startedReads, 5);
    });

    test('geri yükleme sürerken çıkış: geç gelen istem kararı eski oturuma aittir (shouldPrompt false kalır)', () async {
      final storage = storedSession();
      storage.memory.readGate = Completer<void>(); // ilk beş okuma yanıtı bekliyor
      final h = start(storage: storage);
      await settle();
      expect(h.state.authStatus, AuthStatus.checking, reason: 'hazırlık');

      await h.state.logout(); // açılış bitmeden kullanıcı "şifre ile giriş"e düşmüş gibi
      storage.memory.readGate!.complete();
      await h.state.ready;
      await settle();

      expect(h.state.authStatus, AuthStatus.unauthenticated);
      expect(h.state.shouldPromptBiometrics, isFalse, reason: 'eski oturumun kararı yeni (oturumsuz) duruma yazılmaz');
    });
  });
}
