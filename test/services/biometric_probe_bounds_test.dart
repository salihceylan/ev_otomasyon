import 'dart:async';

import 'package:ev_otomasyon/services/biometric_auth_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';

import '../support/support.dart';

/// `BiometricAuthService` süre sınırı (PF-02): destek/tür SONDALARI platform kanalında takılabilir; 3 sn
/// içinde dönmezse "biyometrik yok" sayılır (açılış/giriş bloklanmaz). Etkileşimli doğrulama istemine
/// ASLA süre sınırı konmaz (kullanıcı okutana ya da vazgeçene kadar beklenir).
void main() {
  late FakeClock clock;
  late _ControlledAuth auth;
  late BiometricAuthService service;

  setUp(() {
    clock = FakeClock();
    auth = _ControlledAuth();
    service = BiometricAuthService(auth: auth, clock: clock);
  });

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

  group('isBiometricSupported', () {
    test('iki sonda da takılırsa 3 sn\'de false (öncesinde beklenir)', () async {
      final out = track(service.isBiometricSupported());

      await clock.elapse(const Duration(seconds: 2, milliseconds: 900));
      expect(out.done, isFalse, reason: '3 sn dolmadan beklemeye devam');
      await clock.elapse(const Duration(milliseconds: 100));
      expect(out.value, isFalse);
      expect(out.error, isNull);
      expect(clock.activeTimerCount, 0);
    });

    test('ilk sonda döner, ikincisi takılırsa TOPLAM 3 sn\'de false (iki ayrı 3 sn değil)', () async {
      final out = track(service.isBiometricSupported());
      await clock.elapse(const Duration(seconds: 1));
      auth.canCheck.complete(true);
      await clock.elapse(const Duration(seconds: 1));
      expect(out.done, isFalse);

      await clock.elapse(const Duration(seconds: 1));
      expect(out.value, isFalse);
    });

    test('sondalar zamanında dönerse: ikisi true -> true; biri false -> false; zamanlayıcı kalmaz', () async {
      auth.canCheck.complete(true);
      auth.deviceSupported.complete(true);
      expect(await service.isBiometricSupported(), isTrue);
      expect(clock.activeTimerCount, 0);

      final other = _ControlledAuth();
      other.canCheck.complete(false);
      other.deviceSupported.complete(true);
      expect(await BiometricAuthService(auth: other, clock: clock).isBiometricSupported(), isFalse);

      final third = _ControlledAuth();
      third.canCheck.complete(true);
      third.deviceSupported.complete(false);
      expect(await BiometricAuthService(auth: third, clock: clock).isBiometricSupported(), isFalse);
      expect(clock.activeTimerCount, 0);
    });

    test('PlatformException -> false (önceki davranış korunur)', () async {
      auth.canCheck.completeError(PlatformException(code: 'NotAvailable'));
      expect(await service.isBiometricSupported(), isFalse);
    });

    test('süre aşıldıktan sonra geç dönen değer ve HATA yutulur (ele alınmamış hata yok)', () async {
      final uncaught = <Object>[];
      await runZonedGuarded<Future<void>>(() async {
        final localClock = FakeClock();
        final localAuth = _ControlledAuth();
        final localService = BiometricAuthService(auth: localAuth, clock: localClock);
        final out = track(localService.isBiometricSupported());
        await localClock.elapse(const Duration(seconds: 4));
        expect(out.value, isFalse);

        localAuth.canCheck.completeError(PlatformException(code: 'GecGelenHata'));
        localAuth.deviceSupported.complete(true);
        await localClock.elapse(Duration.zero);
        expect(out.value, isFalse, reason: 'geç sonuç zaman aşımı sonucunu ezmez');
      }, (error, stack) => uncaught.add(error));
      expect(uncaught, isEmpty);
    });

    test('probeTimeout ayarlanabilir; varsayılan 3 sn', () async {
      expect(BiometricAuthService.defaultProbeTimeout, const Duration(seconds: 3));
      final fast = BiometricAuthService(auth: auth, clock: clock, probeTimeout: const Duration(seconds: 1));
      final out = track(fast.isBiometricSupported());
      await clock.elapse(const Duration(milliseconds: 1100));
      expect(out.value, isFalse);
    });
  });

  group('lastSupportProbeTimedOut: "desteklenmiyor" ile "platform yanıt vermedi" ayrımı', () {
    test('başlangıçta false; sonda takılırsa true; sonraki zamanında dönen sonda tekrar false', () async {
      expect(service.lastSupportProbeTimedOut, isFalse);

      final hung = track(service.isBiometricSupported());
      await clock.elapse(const Duration(seconds: 3));
      expect(hung.value, isFalse);
      expect(service.lastSupportProbeTimedOut, isTrue, reason: 'false = zaman aşımı (cihaz desteği bilinmiyor)');

      final healthy = _ControlledAuth()
        ..canCheck.complete(true)
        ..deviceSupported.complete(true);
      final healthyService = BiometricAuthService(auth: healthy, clock: clock);
      expect(await healthyService.isBiometricSupported(), isTrue);
      expect(healthyService.lastSupportProbeTimedOut, isFalse);
    });

    test('cihaz gerçekten desteklemiyorsa (false) ya da PlatformException: zaman aşımı DEĞİL', () async {
      final unsupported = _ControlledAuth()
        ..canCheck.complete(false)
        ..deviceSupported.complete(true);
      final unsupportedService = BiometricAuthService(auth: unsupported, clock: clock);
      expect(await unsupportedService.isBiometricSupported(), isFalse);
      expect(unsupportedService.lastSupportProbeTimedOut, isFalse, reason: 'cihaz yanıt verdi: desteklemiyor');

      final failing = _ControlledAuth();
      final failingService = BiometricAuthService(auth: failing, clock: clock);
      final out = track(failingService.isBiometricSupported());
      failing.canCheck.completeError(PlatformException(code: 'NotAvailable'));
      await clock.elapse(Duration.zero);
      expect(out.value, isFalse);
      expect(failingService.lastSupportProbeTimedOut, isFalse);
    });

    test('tür sondası ve doğrulama istemi bayrağı değiştirmez', () async {
      final hung = track(service.isBiometricSupported());
      await clock.elapse(const Duration(seconds: 3));
      expect(hung.value, isFalse);
      expect(service.lastSupportProbeTimedOut, isTrue);

      auth.enrolled.complete(<BiometricType>[BiometricType.face]);
      await service.getAvailableBiometrics();
      expect(service.lastSupportProbeTimedOut, isTrue, reason: 'getAvailableBiometrics bayrağa dokunmaz');
    });
  });

  group('getAvailableBiometrics / getBiometricLabel', () {
    test('sonda takılırsa 3 sn\'de boş liste; döndüyse tür listesi', () async {
      final out = track(service.getAvailableBiometrics());
      await clock.elapse(const Duration(seconds: 2, milliseconds: 900));
      expect(out.done, isFalse);
      await clock.elapse(const Duration(milliseconds: 100));
      expect(out.value, isEmpty);

      final answered = _ControlledAuth()..enrolled.complete(<BiometricType>[BiometricType.fingerprint]);
      expect(await BiometricAuthService(auth: answered, clock: clock).getAvailableBiometrics(), <BiometricType>[BiometricType.fingerprint]);
      expect(clock.activeTimerCount, 0);
    });

    test('PlatformException -> boş liste', () async {
      auth.enrolled.completeError(PlatformException(code: 'x'));
      expect(await service.getAvailableBiometrics(), isEmpty);
    });

    test('etiket: sonda takılırsa 3 sn\'de "Biyometrik Giriş"; yanıt gelirse tür etiketi', () async {
      final out = track(service.getBiometricLabel());
      await clock.elapse(const Duration(seconds: 3));
      expect(out.value, 'Biyometrik Giriş');

      final face = _ControlledAuth()..enrolled.complete(<BiometricType>[BiometricType.face]);
      expect(await BiometricAuthService(auth: face, clock: clock).getBiometricLabel(), 'Face ID');
      final finger = _ControlledAuth()..enrolled.complete(<BiometricType>[BiometricType.fingerprint]);
      expect(await BiometricAuthService(auth: finger, clock: clock).getBiometricLabel(), 'Parmak İzi');
    });
  });

  group('authenticate: etkileşimli istem SÜRE SINIRSIZDIR', () {
    test('sondalar tamam, istem hiç dönmüyor: 30 dk sonra bile bekler; kullanıcı okutunca true', () async {
      auth.canCheck.complete(true);
      auth.deviceSupported.complete(true);
      final out = track(service.authenticate());

      await clock.elapse(const Duration(minutes: 30));
      expect(out.done, isFalse, reason: 'kullanıcı parmağını okutana kadar süre sınırı YOK');
      expect(auth.promptCalls, 1);

      auth.prompt.complete(true);
      await clock.elapse(Duration.zero);
      expect(out.value, isTrue);
      expect(clock.activeTimerCount, 0);
    });

    test('kullanıcı vazgeçerse (false) false döner; platform hatası false döner', () async {
      auth.canCheck.complete(true);
      auth.deviceSupported.complete(true);
      auth.prompt.complete(false);
      expect(await service.authenticate(), isFalse);

      final failing = _ControlledAuth()
        ..canCheck.complete(true)
        ..deviceSupported.complete(true);
      final out = track(BiometricAuthService(auth: failing, clock: clock).authenticate());
      await clock.elapse(Duration.zero); // sondalar bitti, istem başladı
      expect(failing.promptCalls, 1);
      failing.prompt.completeError(PlatformException(code: 'LockedOut'));
      await clock.elapse(Duration.zero);
      expect(out.value, isFalse);
      expect(out.error, isNull);
    });

    test('destek sondası takılırsa istem HİÇ açılmaz: 3 sn\'de false', () async {
      final out = track(service.authenticate());
      await clock.elapse(const Duration(seconds: 3));
      expect(out.value, isFalse);
      expect(auth.promptCalls, 0, reason: 'desteklenmeyen/yanıtsız cihazda istem gösterilmez');
    });

    test('başarısızlık nedeni: sonda takılırsa "hata" (yeniden dene); cihaz gerçekten desteklemiyorsa "kullanılamıyor"', () async {
      final hung = track(service.authenticate());
      await clock.elapse(const Duration(seconds: 3));
      expect(hung.value, isFalse);
      expect(service.lastFailure, BiometricFailure.error,
          reason: 'platform yanıt vermedi: kullanıcıya "cihaz desteklemiyor" denmez');

      final unsupported = _ControlledAuth()
        ..canCheck.complete(false)
        ..deviceSupported.complete(true);
      final unsupportedService = BiometricAuthService(auth: unsupported, clock: clock);
      expect(await unsupportedService.authenticate(), isFalse);
      expect(unsupportedService.lastFailure, BiometricFailure.notAvailable);
      expect(unsupported.promptCalls, 0);
    });

    test('doğrulama seçenekleri korunur (stickyAuth, useErrorDialogs, biometricOnly iletilir)', () async {
      auth.canCheck.complete(true);
      auth.deviceSupported.complete(true);
      auth.prompt.complete(true);
      expect(await service.authenticate(reason: 'Test nedeni', biometricOnly: true), isTrue);
      expect(auth.lastReason, 'Test nedeni');
      expect(auth.lastOptions?.biometricOnly, isTrue);
      expect(auth.lastOptions?.stickyAuth, isTrue);
      expect(auth.lastOptions?.useErrorDialogs, isTrue);
    });
  });

  group('FakeBiometric (üretim servisinin test ikizi)', () {
    test('supportedCalls / labelCalls sayılır', () async {
      final fake = FakeBiometric(supported: true, label: 'Face ID');
      expect(await fake.isBiometricSupported(), isTrue);
      expect(await fake.isBiometricSupported(), isTrue);
      expect(await fake.getBiometricLabel(), 'Face ID');
      expect(fake.supportedCalls, 2);
      expect(fake.labelCalls, 1);
      expect(fake.authenticateCalls, 0);
    });

    test('hangSupported: sonda takılır, üretim servisi gibi 3 sn\'de false; geç değer/hata yutulur', () async {
      final uncaught = <Object>[];
      await runZonedGuarded<Future<void>>(() async {
        final localClock = FakeClock();
        final fake = FakeBiometric(supported: true, clock: localClock);
        final gate = Completer<bool>();
        fake.hangSupported = gate;
        final out = track(fake.isBiometricSupported());

        await localClock.elapse(const Duration(seconds: 2, milliseconds: 900));
        expect(out.done, isFalse);
        await localClock.elapse(const Duration(milliseconds: 100));
        expect(out.value, isFalse);
        expect(fake.supportedCalls, 1);

        gate.completeError(StateError('geç sonda hatası'));
        await localClock.elapse(Duration.zero);
        expect(out.value, isFalse);
      }, (error, stack) => uncaught.add(error));
      expect(uncaught, isEmpty);
    });

    test('hangSupported: süre içinde tamamlanırsa onun değeri döner (zaman aşımı bayrağı false)', () async {
      final localClock = FakeClock();
      final fake = FakeBiometric(clock: localClock);
      final gate = Completer<bool>();
      fake.hangSupported = gate;
      final out = track(fake.isBiometricSupported());
      await localClock.elapse(const Duration(seconds: 1));
      expect(out.done, isFalse);

      gate.complete(true);
      await localClock.elapse(Duration.zero);
      expect(out.value, isTrue);
      expect(fake.lastSupportProbeTimedOut, isFalse);
    });

    test('lastSupportProbeTimedOut: hangSupported zaman aşımında true; takılmayan sonda (supported=false dahil) false', () async {
      final localClock = FakeClock();
      final fake = FakeBiometric(clock: localClock, supported: false);
      expect(fake.lastSupportProbeTimedOut, isFalse);
      expect(await fake.isBiometricSupported(), isFalse);
      expect(fake.lastSupportProbeTimedOut, isFalse, reason: '"desteklenmiyor" zaman aşımı değildir');

      fake.hangSupported = Completer<bool>();
      final out = track(fake.isBiometricSupported());
      await localClock.elapse(const Duration(seconds: 3));
      expect(out.value, isFalse);
      expect(fake.lastSupportProbeTimedOut, isTrue);

      fake.hangSupported = null;
      expect(await fake.isBiometricSupported(), isFalse);
      expect(fake.lastSupportProbeTimedOut, isFalse, reason: 'sonraki sonda bayrağı sıfırlar');
    });

    test('StateHarness FakeBiometric\'i harness saatine bağlar (h.clock.elapse sondayı zaman aşımına uğratır)', () async {
      final h = StateHarness();
      addTearDown(h.dispose);
      h.biometric.hangSupported = Completer<bool>();
      final out = track(h.biometric.isBiometricSupported());

      await h.clock.elapse(const Duration(seconds: 3));
      expect(out.value, isFalse);
    });
  });
}

/// `LocalAuthentication` yerine geçer: her platform çağrısı testin tamamladığı `Completer`'a bağlıdır
/// (hiç tamamlanmazsa çağrı "takılmış" olur).
class _ControlledAuth extends LocalAuthentication {
  final Completer<bool> canCheck = Completer<bool>();
  final Completer<bool> deviceSupported = Completer<bool>();
  final Completer<List<BiometricType>> enrolled = Completer<List<BiometricType>>();
  final Completer<bool> prompt = Completer<bool>();
  int promptCalls = 0;
  String? lastReason;
  AuthenticationOptions? lastOptions;

  @override
  Future<bool> get canCheckBiometrics => canCheck.future;

  @override
  Future<bool> isDeviceSupported() => deviceSupported.future;

  @override
  Future<List<BiometricType>> getAvailableBiometrics() => enrolled.future;

  // `authMessages` tipi (`AuthMessages`) local_auth tarafından dışa aktarılmaz; geniş tip (Object?) geçerli bir
  // geçersiz kılmadır (parametre türü üst tür olabilir).
  @override
  Future<bool> authenticate({
    required String localizedReason,
    Iterable<Object?> authMessages = const <Object?>[],
    AuthenticationOptions options = const AuthenticationOptions(),
  }) {
    promptCalls++;
    lastReason = localizedReason;
    lastOptions = options;
    return prompt.future;
  }
}

class _Box<T> {
  bool done = false;
  T? value;
  Object? error;
}
