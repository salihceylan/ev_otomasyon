import 'dart:async';
import 'dart:convert';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/services/secure_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/support.dart';

/// `SecureStorageService` süre sınırı (PF-02): Keystore/Keychain çağrısı hiç dönmezse her işlem
/// `opTimeout` (6 sn) sonunda `SecureStorageException(op, TimeoutException)` olur; oturum açılışı, çıkış
/// ve belirteç yazımı sonsuza dek bloklanmaz. Zamanlayıcılar `FakeClock` ile deterministiktir.
void main() {
  const sentinel = 'sentinel-token-0001';
  const user = UserModel(id: 'user-1', email: 'ayse@ornek.test', fullName: 'Ayşe Yılmaz');

  late FakeClock clock;
  late InMemorySecureStore store;
  late SecureStorageService service;

  setUp(() {
    clock = FakeClock();
    store = InMemorySecureStore();
    service = SecureStorageService(store: store, clock: clock, opTimeout: const Duration(seconds: 6));
  });

  /// Sonucu bir kutuya yazar (değer ya da hata): "henüz dönmedi" gözlenebilsin diye.
  _Box<T> track<T>(Future<T> future) {
    final box = _Box<T>();
    future.then<void>((value) {
      box.done = true;
      box.value = value;
    }, onError: (Object error) {
      box.done = true;
      box.error = error;
    });
    return box;
  }

  Matcher timeoutOf(String operation) => isA<SecureStorageException>()
      .having((e) => e.operation, 'operation', operation)
      .having((e) => e.cause, 'cause', isA<TimeoutException>())
      .having((e) => e.message, 'message', isNot(contains(sentinel)));

  // Her genel API yolu hangi platform kapısına takılır: okuma / yazma / silme / toplu silme.
  final reads = <String, Future<Object?> Function(SecureStorageService)>{
    'getAuthToken': (s) => s.getAuthToken(),
    'getRefreshToken': (s) => s.getRefreshToken(),
    'getUser': (s) => s.getUser(),
    'getServiceSession': (s) => s.getServiceSession(),
    'isBiometricEnabled': (s) => s.isBiometricEnabled(),
    'isBiometricPromptShown': (s) => s.isBiometricPromptShown(),
    'getLocalKey': (s) => s.getLocalKey('AHBU-S3-1A2B3C'),
    'loadHomesCache': (s) => s.loadHomesCache('user-1'),
  };
  final writes = <String, Future<Object?> Function(SecureStorageService)>{
    'saveAuthToken': (s) => s.saveAuthToken(sentinel),
    'saveRefreshToken': (s) => s.saveRefreshToken(sentinel),
    'saveUser': (s) => s.saveUser(user),
    'saveBiometricEnabled': (s) => s.saveBiometricEnabled(true),
    'saveBiometricPromptShown': (s) => s.saveBiometricPromptShown(true),
    'saveLocalKey': (s) => s.saveLocalKey('AHBU-S3-1A2B3C', sentinel),
    'saveHomesCache': (s) => s.saveHomesCache('user-1', <HomeModel>[testHome()]),
    'saveServiceSession': (s) => s.saveServiceSession(
          ServiceSessionInfo(homeId: kHomeA, homeName: 'Ev A', expiresAt: DateTime.utc(2030), technicianName: 'T'),
        ),
  };
  final deletes = <String, Future<Object?> Function(SecureStorageService)>{
    'deleteAuthToken': (s) => s.deleteAuthToken(),
    'deleteRefreshToken': (s) => s.deleteRefreshToken(),
    'deleteUser': (s) => s.deleteUser(),
    'deleteLocalKey': (s) => s.deleteLocalKey('AHBU-S3-1A2B3C'),
    'deleteHomesCache': (s) => s.deleteHomesCache(),
    'deleteServiceSession': (s) => s.deleteServiceSession(),
  };

  group('takılan platform çağrısı opTimeout (6 sn) sonunda SecureStorageException olur', () {
    for (final entry in reads.entries) {
      test('okuma ${entry.key}: 6 sn dolmadan bekler, sonra SecureStorageException(read, TimeoutException)', () async {
        store.hangReads = Completer<void>();
        final out = track(entry.value(service));

        await clock.elapse(const Duration(seconds: 5, milliseconds: 900));
        expect(out.done, isFalse, reason: '6 sn dolmadan beklemeye devam');
        await clock.elapse(const Duration(milliseconds: 200));
        expect(out.error, timeoutOf('read'));
        expect(clock.activeTimerCount, 0);
      });
    }

    for (final entry in writes.entries) {
      test('yazma ${entry.key}: SecureStorageException(write, TimeoutException)', () async {
        store.hangWrites = Completer<void>();
        final out = track(entry.value(service));

        await clock.elapse(const Duration(seconds: 5, milliseconds: 900));
        expect(out.done, isFalse);
        await clock.elapse(const Duration(milliseconds: 200));
        expect(out.error, timeoutOf('write'));
        expect(clock.activeTimerCount, 0);
      });
    }

    for (final entry in deletes.entries) {
      test('silme ${entry.key}: SecureStorageException(delete, TimeoutException)', () async {
        store.hangWrites = Completer<void>();
        final out = track(entry.value(service));

        await clock.elapse(const Duration(seconds: 5, milliseconds: 900));
        expect(out.done, isFalse);
        await clock.elapse(const Duration(milliseconds: 200));
        expect(out.error, timeoutOf('delete'));
        expect(clock.activeTimerCount, 0);
      });
    }

    test('clearAll: SecureStorageException(deleteAll, TimeoutException)', () async {
      store.hangDeleteAll = Completer<void>();
      final out = track(service.clearAll());

      await clock.elapse(const Duration(seconds: 5, milliseconds: 900));
      expect(out.done, isFalse);
      await clock.elapse(const Duration(milliseconds: 200));
      expect(out.error, timeoutOf('deleteAll'));
      expect(clock.activeTimerCount, 0);
    });

    test('her işlemin KENDİ sınırı vardır: iki ardışık takılma 12 sn\'de biter (biri diğerini uzatmaz)', () async {
      store.hangReads = Completer<void>();
      final first = track(service.getAuthToken());
      await clock.elapse(const Duration(seconds: 7));
      expect(first.error, timeoutOf('read'));

      final second = track(service.getRefreshToken());
      await clock.elapse(const Duration(seconds: 5));
      expect(second.done, isFalse);
      await clock.elapse(const Duration(seconds: 2));
      expect(second.error, timeoutOf('read'));
    });

    test('bozuk kullanıcı kaydı silinirken depo takılırsa getUser yine de null döner (temizlik hatası yutulur)', () async {
      store.data['ahbu_current_user'] = '{bozuk';
      store.hangWrites = Completer<void>();
      final out = track(service.getUser());

      await clock.elapse(const Duration(seconds: 5));
      expect(out.done, isFalse, reason: 'bozuk kaydın silinmesi (delete) 6 sn sınırına kadar beklenir');
      await clock.elapse(const Duration(seconds: 2));
      expect(out.done, isTrue);
      expect(out.error, isNull);
      expect(out.value, isNull);
    });
  });

  group('süre sınırı ayarları', () {
    test('üretim varsayılanı 6 sn (ne 5,9 ne 6,1)', () async {
      expect(SecureStorageService.defaultOpTimeout, const Duration(seconds: 6));
      final byDefault = SecureStorageService(store: store, clock: clock);
      store.hangReads = Completer<void>();
      final out = track(byDefault.getAuthToken());

      await clock.elapse(const Duration(seconds: 5, milliseconds: 999));
      expect(out.done, isFalse);
      await clock.elapse(const Duration(milliseconds: 1));
      expect(out.error, timeoutOf('read'));
    });

    test('opTimeout ayarlanabilir', () async {
      final fast = SecureStorageService(store: store, clock: clock, opTimeout: const Duration(seconds: 2));
      store.hangReads = Completer<void>();
      final out = track(fast.getAuthToken());

      await clock.elapse(const Duration(seconds: 1, milliseconds: 900));
      expect(out.done, isFalse);
      await clock.elapse(const Duration(milliseconds: 200));
      expect(out.error, timeoutOf('read'));
    });
  });

  group('zaman aşımı sonrası', () {
    test('kapı sonradan açılınca (değerle) işlenmemiş hata YOK; belirteç silinmez', () async {
      final uncaught = <Object>[];
      await runZonedGuarded<Future<void>>(() async {
        final localClock = FakeClock();
        final localStore = InMemorySecureStore()..data['ahbu_auth_token'] = sentinel;
        final localService = SecureStorageService(store: localStore, clock: localClock);
        final gate = Completer<void>();
        localStore.hangReads = gate;
        final out = track(localService.getAuthToken());
        await localClock.elapse(const Duration(seconds: 7));
        expect(out.error, timeoutOf('read'));

        gate.complete();
        await localClock.elapse(Duration.zero);
        expect(out.error, timeoutOf('read'), reason: 'geç gelen değer sonucu değiştirmez');
        expect(localStore.data['ahbu_auth_token'], sentinel, reason: 'zaman aşımı kaydı silmez');
      }, (error, stack) => uncaught.add(error));
      expect(uncaught, isEmpty);
    });

    test('kapı sonradan HATAYLA açılınca da işlenmemiş hata YOK (her işlem türü)', () async {
      final uncaught = <Object>[];
      await runZonedGuarded<Future<void>>(() async {
        final localClock = FakeClock();
        final localStore = InMemorySecureStore();
        final localService = SecureStorageService(store: localStore, clock: localClock);
        final readGate = Completer<void>();
        final writeGate = Completer<void>(); // write VE delete aynı kapıya takılır
        final deleteAllGate = Completer<void>();
        localStore
          ..hangReads = readGate
          ..hangWrites = writeGate
          ..hangDeleteAll = deleteAllGate;

        final outs = <_Box<Object?>>[
          track<Object?>(localService.getAuthToken()),
          track<Object?>(localService.saveAuthToken(sentinel)),
          track<Object?>(localService.deleteAuthToken()),
          track<Object?>(localService.clearAll()),
        ];
        await localClock.elapse(const Duration(seconds: 7));
        expect(outs.every((o) => o.error is SecureStorageException), isTrue);

        readGate.completeError(StateError('geç okuma hatası'));
        writeGate.completeError(StateError('geç yazma/silme hatası'));
        deleteAllGate.completeError(StateError('geç toplu silme hatası'));
        await localClock.elapse(Duration.zero);
      }, (error, stack) => uncaught.add(error));
      expect(uncaught, isEmpty, reason: 'süreyi aşan çağrının geç hatası main.dart onError\'una düşmemeli');
    });

    test('zaman aşımına uğrayan yazma İPTAL EDİLMEZ: kapı açılınca platform işi sürer ve kayıt düşer', () async {
      final gate = Completer<void>();
      store.hangWrites = gate;
      final out = track(service.saveAuthToken(sentinel));
      await clock.elapse(const Duration(seconds: 7));
      expect(out.error, timeoutOf('write'));
      expect(store.data, isEmpty, reason: 'platform henüz yazmadı');

      gate.complete();
      await clock.elapse(Duration.zero);
      expect(store.data['ahbu_auth_token'], sentinel);
    });
  });

  group('normal işlemler etkilenmez', () {
    test('hemen dönen işlemlerde değerler doğru, zamanlayıcı kalmaz, saat ilerlese de zaman aşımı olmaz', () async {
      await service.saveAuthToken(sentinel);
      await service.saveRefreshToken('refresh-0002');
      await service.saveUser(user);
      expect(clock.activeTimerCount, 0);

      expect(await service.getAuthToken(), sentinel);
      expect(await service.getRefreshToken(), 'refresh-0002');
      expect((await service.getUser())?.id, 'user-1');
      expect(await service.isBiometricEnabled(), isFalse);
      expect(clock.activeTimerCount, 0, reason: 'tamamlanan her işlem sınır zamanlayıcısını iptal eder');

      await clock.elapse(const Duration(hours: 1));
      await service.clearAll();
      expect(store.data, isEmpty);
      expect(await service.getAuthToken(), isNull, reason: 'kayıt yok != zaman aşımı: null döner');
    });

    test('platform hatası zaman aşımına ÇEVRİLMEZ: SecureStorageException asıl hatayı taşır', () async {
      store.failReads = true;
      await expectLater(
        service.getAuthToken(),
        throwsA(isA<SecureStorageException>()
            .having((e) => e.operation, 'operation', 'read')
            .having((e) => e.cause, 'cause', isNot(isA<TimeoutException>()))),
      );
      store.failReads = false;

      store.failWrites = true;
      await expectLater(
        service.saveAuthToken(sentinel),
        throwsA(isA<SecureStorageException>().having((e) => e.cause, 'cause', isNot(isA<TimeoutException>()))),
      );
      store.failWrites = false;

      store.failDeleteAll = true;
      await expectLater(
        service.clearAll(),
        throwsA(isA<SecureStorageException>()
            .having((e) => e.operation, 'operation', 'deleteAll')
            .having((e) => e.cause, 'cause', isNot(isA<TimeoutException>()))),
      );
      expect(clock.activeTimerCount, 0);
    });

    test('gecikmeli ama süre içinde dönen yanıt (readGate) kabul edilir: değer kapıdan ÖNCE yakalanır', () async {
      store.data['ahbu_auth_token'] = 'eski';
      final gate = Completer<void>();
      store.readGate = gate;
      final out = track(service.getAuthToken());
      await clock.elapse(const Duration(seconds: 3));
      expect(out.done, isFalse);

      store.data['ahbu_auth_token'] = 'yeni'; // platform değeri zaten okumuştu
      gate.complete();
      await clock.elapse(Duration.zero);
      expect(out.value, 'eski');
      expect(out.error, isNull);
    });

    test('hata ayıklama sayaçları: startedReads / writeCount / writeCountFor / deleteAllCount', () async {
      await service.saveAuthToken(sentinel);
      await service.saveAuthToken(sentinel);
      await service.saveRefreshToken('r');
      await service.getAuthToken();
      await service.getUser();
      await service.deleteAuthToken();
      await service.clearAll();

      expect(store.writeCount, 3, reason: 'delete yazma sayılmaz');
      expect(store.writeCountFor('ahbu_auth_token'), 2);
      expect(store.writeCountFor('ahbu_refresh_token'), 1);
      expect(store.writeCountFor('olmayan'), 0);
      expect(store.startedReads, 2);
      expect(store.deleteAllCount, 1);
    });
  });

  group('FakeStorage / StateHarness saat bağlantısı', () {
    test('FakeStorage(clock:) açıkça verilen saatle zaman aşımına uğrar', () async {
      final fake = FakeStorage(memory: store, clock: clock);
      store.hangReads = Completer<void>();
      final out = track(fake.getAuthToken());
      await clock.elapse(const Duration(seconds: 7));
      expect(out.error, timeoutOf('read'));
    });

    test('FakeStorage saat verilmezse ATIL: gerçek zaman da, başka saat de onu zaman aşımına uğratmaz', () async {
      final fake = FakeStorage(memory: store);
      store.hangReads = Completer<void>();
      final out = track(fake.getAuthToken());
      await clock.elapse(const Duration(minutes: 5));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(out.done, isFalse);
    });

    test('StateHarness varsayılan deposu harness saatine bağlıdır: h.clock.elapse takılan çağrıyı zaman aşımına uğratır', () async {
      final h = StateHarness();
      addTearDown(h.dispose);
      h.storage.memory.hangReads = Completer<void>();
      final out = track(h.storage.getAuthToken());

      await h.clock.elapse(const Duration(seconds: 7));
      expect(out.error, timeoutOf('read'));
    });

    test('kendi FakeStorage\'ını (saatsiz) harness\'a veren test de aynı bağlantıyı alır', () async {
      final own = FakeStorage();
      final h = StateHarness(storage: own);
      addTearDown(h.dispose);
      own.memory.hangWrites = Completer<void>();
      final out = track(own.saveAuthToken(sentinel));

      await h.clock.elapse(const Duration(seconds: 7));
      expect(out.error, timeoutOf('write'));
    });

    test('açıkça saat verilen FakeStorage harness tarafından yeniden bağlanmaz', () async {
      final ownClock = FakeClock();
      final own = FakeStorage(clock: ownClock);
      final h = StateHarness(storage: own);
      addTearDown(h.dispose);
      own.memory.hangReads = Completer<void>();
      final out = track(own.getAuthToken());

      await h.clock.elapse(const Duration(seconds: 30));
      expect(out.done, isFalse, reason: 'harness saati bu depoyu ilgilendirmez');
      await ownClock.elapse(const Duration(seconds: 7));
      expect(out.error, timeoutOf('read'));
    });
  });

  group('AutomationState ile (üretim yolu, harness saati)', () {
    test('açılışta okuma takılırsa: 15 sn içinde açılış biter, storageError yüzeye çıkar, geç dönen okuma oturumu geri DÖNDÜRMEZ',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final memory = InMemorySecureStore()
        ..data['ahbu_auth_token'] = 'stored-access'
        ..data['ahbu_refresh_token'] = 'stored-refresh'
        ..data['ahbu_current_user'] = jsonEncode(user.toJson());
      final gate = Completer<void>();
      memory.hangReads = gate;
      final h = StateHarness(autoInit: true, storage: FakeStorage(memory: memory));
      addTearDown(h.dispose);

      await h.clock.elapse(const Duration(seconds: 15));
      await h.state.ready.timeout(const Duration(seconds: 3), onTimeout: () => fail('ready tamamlanmadı: açılış hâlâ takılı'));

      expect(h.state.authStatus, AuthStatus.unauthenticated, reason: 'oturum geri yüklenemedi: giriş ekranı');
      expect(h.state.storageError, isNotNull, reason: 'depo hatası kullanıcıya yüzeye çıkar');
      expect(h.cloud.calls, isEmpty, reason: 'belirteç okunamadı: ağ çağrısı yok');

      gate.complete(); // platform geç yanıt verdi
      await h.clock.elapse(const Duration(seconds: 1));
      expect(h.state.authStatus, AuthStatus.unauthenticated, reason: 'geç dönen okuma oturumu geri döndürmez');
      expect(h.state.isAuthenticated, isFalse);
      expect(memory.data['ahbu_auth_token'], 'stored-access', reason: 'belirteç SİLİNMEDİ (sonraki açılışta düzelir)');
    });

    test('login(): giriş sonrası depo okuması takılırsa giriş 10 sn içinde tamamlanır (eskiden _handleAuthSuccess sonsuza dek bloklanırdı)',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final h = StateHarness();
      addTearDown(h.dispose);
      h.cloud.homes = <HomeModel>[testHome()];
      h.cloud.endpoints[kHomeA] = testEndpoints();
      h.cloud.devicesByHome[kHomeA] = <DeviceInfo>[
        const DeviceInfo(deviceUuid: 'AHBU-S3-TEST01', name: 'Pano', online: true, firmware: '1.1.0'),
      ];
      h.storage.memory
        ..hangReads = Completer<void>() // biyometrik istem bayrağı okuması
        ..hangWrites = Completer<void>(); // arka plandaki belirteç yazımı

      final out = track(h.state.login('a@b.c', 'parola-1234'));
      await h.clock.elapse(const Duration(seconds: 5));
      expect(out.done, isFalse, reason: 'bayrak okuması 6 sn sınırına kadar beklenir');
      expect(h.state.authStatus, AuthStatus.authenticated, reason: 'kullanıcı/oturum bellekte hazır');

      await h.clock.elapse(const Duration(seconds: 5));
      expect(out.error, isNull);
      expect(out.value, isTrue, reason: 'depo takılı olsa da giriş tamamlanır');
      expect(h.state.activeHome?.id, kHomeA, reason: 'ev listesi yüklendi, ilk ev seçildi');
      expect(h.state.shouldPromptBiometrics, isFalse, reason: 'bayrak okunamadı: istem gösterilmez (güvenli taraf)');
    });

    test('logout(): çıkıştaki toplu silme takılırsa 10 sn içinde biter, oturum kapanır, depo hatası bildirilir', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      expect(h.state.isAuthenticated, isTrue);
      h.storage.memory.hangDeleteAll = Completer<void>();

      final out = track(h.state.logout());
      await h.clock.elapse(const Duration(seconds: 5));
      expect(out.done, isFalse, reason: 'platform toplu silmesi 6 sn sınırına kadar beklenir');
      expect(h.state.authStatus, AuthStatus.unauthenticated, reason: 'yerel oturum temizliği beklemeden yapılır');

      await h.clock.elapse(const Duration(seconds: 5));
      expect(out.done, isTrue, reason: 'toplam 10 sn içinde çıkış tamamlanır (eskiden sonsuza dek bloklanırdı)');
      expect(out.error, isNull);
      expect(h.state.storageError, isNotNull);
    });
  });
}

class _Box<T> {
  bool done = false;
  T? value;
  Object? error;
}
