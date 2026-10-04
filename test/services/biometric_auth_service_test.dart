import 'dart:async';

import 'package:ev_otomasyon/services/biometric_auth_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:local_auth_android/local_auth_android.dart';

/// `LocalAuthentication` sahtesi: çağrıları kaydeder; sonucu ya da fırlatılacak hatayı test belirler.
class _FakeLocalAuth implements LocalAuthentication {
  bool hardware = true;
  bool deviceSupported = true;
  bool result = true;
  Object? error;

  /// Atanırsa `authenticate` tamamlanana kadar bekler (askıdaki sistem istemi).
  Completer<bool>? gate;

  int authenticateCalls = 0;
  Iterable<AuthMessages>? lastMessages;
  AuthenticationOptions? lastOptions;

  @override
  Future<bool> authenticate({
    required String localizedReason,
    Iterable<AuthMessages> authMessages = const <AuthMessages>[],
    AuthenticationOptions options = const AuthenticationOptions(),
  }) async {
    authenticateCalls++;
    lastMessages = authMessages;
    lastOptions = options;
    final failure = error;
    if (failure != null) throw failure;
    final pending = gate;
    if (pending != null) return pending.future;
    return result;
  }

  @override
  Future<bool> get canCheckBiometrics async => hardware;

  @override
  Future<bool> isDeviceSupported() async => deviceSupported;

  @override
  Future<List<BiometricType>> getAvailableBiometrics() async => const <BiometricType>[BiometricType.strong];

  @override
  Future<bool> stopAuthentication() async => true;
}

/// Biyometrik sarmalayıcı: doğrulama neden başarısız olduysa bu bilgi kaybolmaz (kullanıcıya doğru açıklama
/// gösterilebilsin) ve sistem istemi Türkçe metinlerle açılır.
void main() {
  late _FakeLocalAuth auth;
  late BiometricAuthService service;

  setUp(() {
    auth = _FakeLocalAuth();
    service = BiometricAuthService(auth: auth);
  });

  group('authenticate: başarısızlık nedeni kaybolmaz', () {
    test('başarılı doğrulamada true döner ve neden yoktur', () async {
      expect(await service.authenticate(reason: 'Doğrula'), isTrue);
      expect(service.lastFailure, isNull);
    });

    test('kullanıcı vazgeçerse ya da eşleşme olmazsa (eklenti false) neden "vazgeçildi"dir', () async {
      auth.result = false;

      expect(await service.authenticate(reason: 'Doğrula'), isFalse);
      expect(service.lastFailure, BiometricFailure.canceled);
    });

    const codes = <String, BiometricFailure>{
      'NotEnrolled': BiometricFailure.notEnrolled,
      'NotAvailable': BiometricFailure.notAvailable,
      'PasscodeNotSet': BiometricFailure.notAvailable,
      'NoHardware': BiometricFailure.notAvailable,
      'LockedOut': BiometricFailure.lockedOut,
      'PermanentlyLockedOut': BiometricFailure.permanentlyLockedOut,
      'auth_in_progress': BiometricFailure.inProgress,
      'UserCancelled': BiometricFailure.canceled,
      'no_activity': BiometricFailure.error,
      'no_fragment_activity': BiometricFailure.error,
      'bilinmeyen_kod': BiometricFailure.error,
    };
    for (final entry in codes.entries) {
      test('eklenti "${entry.key}" hatası verirse false döner ve neden ${entry.value.name} olur', () async {
        auth.error = PlatformException(code: entry.key);

        expect(await service.authenticate(reason: 'Doğrula'), isFalse);
        expect(service.lastFailure, entry.value);
      });
    }

    test('cihaz desteklemiyorsa eklenti çağrılmaz ve neden "kullanılamıyor"dur', () async {
      auth.deviceSupported = false;

      expect(await service.authenticate(reason: 'Doğrula'), isFalse);
      expect(auth.authenticateCalls, 0);
      expect(service.lastFailure, BiometricFailure.notAvailable);
    });

    test('beklenmeyen istisna çökertmez; neden "hata"dır', () async {
      auth.error = StateError('kanal koptu');

      expect(await service.authenticate(reason: 'Doğrula'), isFalse);
      expect(service.lastFailure, BiometricFailure.error);
    });

    test('sonraki başarılı doğrulama eski nedeni temizler', () async {
      auth.error = PlatformException(code: 'LockedOut');
      await service.authenticate(reason: 'Doğrula');
      expect(service.lastFailure, BiometricFailure.lockedOut);

      auth.error = null;
      expect(await service.authenticate(reason: 'Doğrula'), isTrue);
      expect(service.lastFailure, isNull);
    });
  });

  group('authenticate: aynı anda tek doğrulama', () {
    test('süren doğrulama varken ikinci çağrı eklentiye gitmez; ikisi de aynı sonucu alır', () async {
      final gate = Completer<bool>();
      auth.gate = gate;

      final first = service.authenticate(reason: 'Kilidi aç');
      final second = service.authenticate(reason: 'Çocuk kilidi');
      await Future<void>.delayed(Duration.zero); // destek sondaları (iki await) tamamlansın
      expect(auth.authenticateCalls, 1, reason: 'eklenti ikinci istemi auth_in_progress ile reddederdi');

      gate.complete(true);
      expect(await first, isTrue);
      expect(await second, isTrue);
      expect(service.lastFailure, isNull);
    });

    test('ilk doğrulama bitince (devamı içinden bile) yeni çağrı yeni istem açar; hata sonrası da uçuş sıfırlanır', () async {
      auth.error = StateError('kanal koptu');
      expect(await service.authenticate(reason: 'Doğrula'), isFalse);
      auth.error = null;

      auth.result = false;
      await service.authenticate(reason: 'Doğrula').then((_) => service.authenticate(reason: 'Yeniden'));
      expect(auth.authenticateCalls, 3);
    });
  });

  group('authenticate: sistem istemi', () {
    test('seçenekler: arka plandan dönüşte sürer, hata diyalogları açık, cihaz kimlik bilgisi yedeği serbest', () async {
      await service.authenticate(reason: 'Doğrula');

      expect(auth.lastOptions!.stickyAuth, isTrue);
      expect(auth.lastOptions!.useErrorDialogs, isTrue);
      expect(auth.lastOptions!.biometricOnly, isFalse);
    });

    test('Android istemindeki bütün metinler Türkçe verilir ve uzunluk sınırlarını aşmaz', () async {
      await service.authenticate(reason: 'Doğrula');

      final messages = auth.lastMessages!.whereType<AndroidAuthMessages>().single;
      // Eklentinin belgelediği üst sınırlar (auth_messages_android.dart): düğmeler 30, diğerleri 60 karakter.
      final limits = <String, (String?, int)>{
        'signInTitle': (messages.signInTitle, 60),
        'biometricHint': (messages.biometricHint, 60),
        'biometricNotRecognized': (messages.biometricNotRecognized, 60),
        'biometricSuccess': (messages.biometricSuccess, 60),
        'biometricRequiredTitle': (messages.biometricRequiredTitle, 60),
        'deviceCredentialsRequiredTitle': (messages.deviceCredentialsRequiredTitle, 60),
        'cancelButton': (messages.cancelButton, 30),
        'goToSettingsButton': (messages.goToSettingsButton, 30),
      };
      for (final entry in limits.entries) {
        final (text, max) = entry.value;
        expect(text, isNotNull, reason: '${entry.key} verilmezse eklentinin İngilizce varsayılanı görünür');
        expect(text!.length, lessThanOrEqualTo(max), reason: '${entry.key} en çok $max karakter olabilir');
      }
      expect(messages.signInTitle, isNotEmpty, reason: 'başlık boş olursa sistem istemi açılmaz');
      expect(messages.deviceCredentialsSetupDescription, isNotNull);
      expect(messages.goToSettingsDescription, isNotNull);
      expect(messages.signInTitle, isNot('Authentication required'));
      expect(messages.cancelButton, isNot('Cancel'));
    });
  });

  group('biometricFailureMessage', () {
    test('vazgeçme ve bilinmeyen durumda genel açıklama verir', () {
      expect(biometricFailureMessage(null, label: 'Parmak İzi'), 'Parmak İzi doğrulaması tamamlanamadı.');
      expect(
        biometricFailureMessage(BiometricFailure.canceled, label: 'Face ID'),
        'Face ID doğrulaması tamamlanamadı.',
      );
    });

    test('her neden için ayrı bir açıklama verir', () {
      final texts = <String>{
        for (final failure in BiometricFailure.values) biometricFailureMessage(failure, label: 'Parmak İzi'),
      };

      expect(texts, hasLength(BiometricFailure.values.length));
      expect(texts.every((text) => text.trim().isNotEmpty), isTrue);
    });

    test('kayıt yoksa ve kilitlenmede kullanıcıya ne yapacağını söyler', () {
      expect(biometricFailureMessage(BiometricFailure.notEnrolled, label: 'Parmak İzi'), contains('kayıtlı'));
      expect(biometricFailureMessage(BiometricFailure.lockedOut, label: 'Parmak İzi'), contains('bekleyin'));
      expect(
        biometricFailureMessage(BiometricFailure.permanentlyLockedOut, label: 'Parmak İzi'),
        contains('PIN'),
      );
    });

    test('fallback verilirse vazgeçme ve bilinmeyen durumda o döner; belirli nedende yok sayılır', () {
      const fallback = 'Kimlik doğrulanamadı.';

      expect(biometricFailureMessage(null, label: 'Parmak İzi', fallback: fallback), fallback);
      expect(biometricFailureMessage(BiometricFailure.canceled, label: 'Parmak İzi', fallback: fallback), fallback);
      expect(
        biometricFailureMessage(BiometricFailure.lockedOut, label: 'Parmak İzi', fallback: fallback),
        contains('hatalı deneme'),
      );
    });
  });
}
