import 'dart:async';
import 'dart:io';

import 'package:ev_otomasyon/services/api_exception.dart';
import 'package:ev_otomasyon/services/automation_api_service.dart';
import 'package:ev_otomasyon/services/secure_storage_service.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/secret_clipboard.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_problem.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';

/// SecretClipboard (45 sn sonra silme) ve hata -> açıklama çevirisi (SetupProblems) davranış testleri.

class _Clip {
  String? text;
  int writes = 0;

  /// Android 10+ arka plan kısıtı: pano okunamaz (`getData` `null` döner), yazma çalışır.
  bool unreadable = false;

  /// Yazmalar sessizce yok sayılır (arka planda yazma da kısıtlı platformlar).
  bool ignoreWrites = false;
}

_Clip _installClipboard() {
  final clip = _Clip();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      if (clip.ignoreWrites) return null;
      clip.text = (call.arguments as Map<Object?, Object?>)['text'] as String?;
      clip.writes++;
      return null;
    }
    if (call.method == 'Clipboard.getData') {
      if (clip.unreadable) return null;
      return clip.text == null ? null : <String, dynamic>{'text': clip.text};
    }
    return null;
  });
  addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  return clip;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SecretClipboard', () {
    late FakeClock clock;
    late _Clip clip;

    setUp(() {
      SecretClipboard.reset();
      clock = FakeClock();
      clip = _installClipboard();
    });
    tearDown(SecretClipboard.reset);

    test('kopyalanan değer 45 saniye sonra panodan silinir; öncesinde durur', () async {
      await SecretClipboard.copy('gizli-deger', clock: clock);
      expect(clip.text, 'gizli-deger');
      expect(SecretClipboard.hasPending, isTrue);

      clock.advance(const Duration(seconds: 44));
      await pumpEventQueue();
      expect(clip.text, 'gizli-deger');
      clock.advance(const Duration(seconds: 2));
      await pumpEventQueue();
      expect(clip.text, isEmpty);
      expect(SecretClipboard.hasPending, isFalse);
    });

    test('kullanıcı bu arada başka bir şey kopyaladıysa onun panosuna dokunulmaz', () async {
      await SecretClipboard.copy('gizli-deger', clock: clock);
      clip.text = 'kullanicinin kendi metni';
      clock.advance(const Duration(seconds: 46));
      await pumpEventQueue();
      expect(clip.text, 'kullanicinin kendi metni');
      expect(SecretClipboard.hasPending, isFalse);
    });

    test('yeni gizli kopya öncekinin süresini iptal eder ve kendi 45 saniyesini alır', () async {
      await SecretClipboard.copy('birinci', clock: clock);
      clock.advance(const Duration(seconds: 30));
      await SecretClipboard.copy('ikinci', clock: clock);
      clock.advance(const Duration(seconds: 20)); // ilk kopyadan 50 sn, ikinciden 20 sn
      await pumpEventQueue();
      expect(clip.text, 'ikinci', reason: 'ikinci kopya henüz 45 sn dolmadı');
      clock.advance(const Duration(seconds: 26));
      await pumpEventQueue();
      expect(clip.text, isEmpty);
    });

    test('wipeNow bekleyen gizli değeri hemen siler (diyalog kapanırken)', () async {
      await SecretClipboard.copy('gizli-deger', clock: clock);
      await SecretClipboard.wipeNow();
      expect(clip.text, isEmpty);
      expect(SecretClipboard.hasPending, isFalse);
      // Bekleyen kopya yokken çağrı zararsızdır.
      clip.text = 'baska';
      await SecretClipboard.wipeNow();
      expect(clip.text, 'baska');
    });

    test('özel silme süresi desteklenir', () async {
      await SecretClipboard.copy('x', clock: clock, wipeAfter: const Duration(seconds: 5));
      clock.advance(const Duration(seconds: 6));
      await pumpEventQueue();
      expect(clip.text, isEmpty);
    });

    group('arka planda silme (Android 10+: uygulama panoyu okuyamaz)', () {
      final binding = TestWidgetsFlutterBinding.instance;

      tearDown(() => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));

      test('arka plandayken pano okunamıyorsa gizli değerin üzerine boş yazılır ve ön plana dönünce doğrulanır', () async {
        await SecretClipboard.copy('gizli-deger', clock: clock);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.paused); // kullanıcı değeri başka uygulamaya yapıştırmaya gitti
        clip.unreadable = true;

        clock.advance(const Duration(seconds: 46));
        await pumpEventQueue();
        expect(clip.text, isEmpty, reason: 'okunamasa da gizli değer panoda bırakılmaz');
        expect(SecretClipboard.hasPending, isTrue, reason: 'içerik doğrulanamadı: ön plana dönünce yeniden denenir');

        clip.unreadable = false;
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await pumpEventQueue();
        expect(clip.text, isEmpty);
        expect(SecretClipboard.hasPending, isFalse, reason: 'ön planda pano okundu ve doğrulandı');
      });

      test('arka planda yazma da yok sayıldıysa değer ön plana dönünce silinir', () async {
        await SecretClipboard.copy('gizli-deger', clock: clock);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        clip
          ..unreadable = true
          ..ignoreWrites = true;

        clock.advance(const Duration(seconds: 46));
        await pumpEventQueue();
        expect(clip.text, 'gizli-deger', reason: 'bu platform arka planda yazmayı da engelledi');
        expect(SecretClipboard.hasPending, isTrue);

        clip
          ..unreadable = false
          ..ignoreWrites = false;
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await pumpEventQueue();
        expect(clip.text, isEmpty, reason: 'ön plana dönüşte yeniden denenir ve silinir');
        expect(SecretClipboard.hasPending, isFalse);
      });

      test('süre dolmadan ön plana dönmek panoyu silmez (yapıştırma süresi korunur)', () async {
        await SecretClipboard.copy('gizli-deger', clock: clock);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        clock.advance(const Duration(seconds: 10));
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await pumpEventQueue();
        expect(clip.text, 'gizli-deger');
        expect(SecretClipboard.hasPending, isTrue);
      });

      test('ön plandayken boş pano doğrulanmış sayılır: kullanıcının sonraki kopyalarına dokunulmaz', () async {
        await SecretClipboard.copy('gizli-deger', clock: clock);
        clip.text = null; // pano boşaltılmış
        clock.advance(const Duration(seconds: 46));
        await pumpEventQueue();
        expect(SecretClipboard.hasPending, isFalse);
        clip.text = 'sonradan kopyalanan';
        binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await pumpEventQueue();
        expect(clip.text, 'sonradan kopyalanan', reason: 'bekleyen silme kalmadığı için ön plana dönüş panoya dokunmaz');
      });
    });
  });

  group('SetupProblems.fromError (hata -> "ne oldu / neden / ne yapmalıyım")', () {
    SetupProblem map(Object error, {int step = 6}) => SetupProblems.fromError(error, step: step);

    test('ağ yok ve zaman aşımı ayrı açıklanır; Wi-Fi adımında internet gerektiği söylenir', () {
      final offline = map(ApiException.network());
      expect(offline.kind, SetupProblemKind.network);
      expect(offline.retryable, isTrue);
      expect(map(ApiException.network(), step: 5).todo, contains('internet gerektirir'));
      final timeout = map(ApiException.network(cause: TimeoutException('x')));
      expect(timeout.kind, SetupProblemKind.timeout);
      expect(map(TimeoutException('x')).kind, SetupProblemKind.timeout);
      expect(map(const SocketException('x')).kind, SetupProblemKind.network);
    });

    test('401 ve servis oturumu bitişi "oturum süresi doldu" olur ve tekrar denenmez', () {
      for (final e in <ApiException>[
        const ApiException(statusCode: 401, code: 'TOKEN_EXPIRED', message: 'x'),
        const ApiException(statusCode: 401, code: 'SERVICE_SESSION_EXPIRED', message: 'x'),
      ]) {
        final p = map(e);
        expect(p.kind, SetupProblemKind.expired);
        expect(p.retryable, isFalse);
        expect(p.todo, contains('Devam eden kurulumlar'));
      }
    });

    test('PIN kilidi: bekleme süresi yazılır; 3. adımdan itibaren 2. adıma yönlendirir', () {
      const e = ApiException(statusCode: 423, code: 'PIN_LOCKED', message: 'k', retryAfter: Duration(minutes: 7));
      final p = map(e, step: 4);
      expect(p.kind, SetupProblemKind.locked);
      expect(p.retryAfter, const Duration(minutes: 7));
      expect(p.todo, contains('7 dakika'));
      expect(p.fixStep, 2);
      expect(map(e, step: 2).fixStep, isNull);
    });

    test('hız sınırı ve cihaz çevrimdışı açıklamaları', () {
      final rate = map(const ApiException(statusCode: 429, code: 'RATE_LIMITED', message: 'r', retryAfter: Duration(seconds: 30)));
      expect(rate.kind, SetupProblemKind.rateLimited);
      expect(rate.todo, contains('30 saniye'));
      final offline = map(const ApiException(statusCode: 409, code: 'DEVICE_OFFLINE', message: 'o'));
      expect(offline.kind, SetupProblemKind.deviceNetwork);
    });

    test('yetki, doğrulama, süresi dolan kod, bulunamadı, çakışma ve sunucu hatası', () {
      expect(map(const ApiException(statusCode: 403, code: 'FORBIDDEN', message: 'y')).retryable, isFalse);
      final validation = map(const ApiException(statusCode: 400, code: 'VALIDATION', message: 'v', remainingAttempts: 2));
      expect(validation.kind, SetupProblemKind.validation);
      expect(validation.todo, contains('Kalan deneme hakkınız: 2'));
      expect(map(const ApiException(statusCode: 410, code: 'GONE', message: 'g')).title, 'Kodun süresi doldu');
      expect(map(const ApiException(statusCode: 404, code: 'NOT_FOUND', message: 'n')).kind, SetupProblemKind.notFound);
      expect(map(const ApiException(statusCode: 409, code: 'CONFLICT', message: 'c')).kind, SetupProblemKind.conflict);
      final server = map(const ApiException(statusCode: 500, code: 'INTERNAL', message: 'sqlite hata detayı'));
      expect(server.kind, SetupProblemKind.server);
      expect(server.why, isNot(contains('sqlite')), reason: 'iç sunucu hatası kullanıcıya sızmaz');
    });

    test('pano (yerel) hataları: anahtar reddi, kilit, hazırlanmamış, meşgul, adres reddi, zaman aşımı, ağ', () {
      expect(map(const LocalApiException(statusCode: 401, message: 'x')).kind, SetupProblemKind.unauthorized);
      final locked = map(const LocalApiException(statusCode: 423, message: 'x', retryAfter: Duration(minutes: 1)));
      expect(locked.kind, SetupProblemKind.locked);
      expect(locked.retryAfter, const Duration(minutes: 1));
      expect(map(const LocalApiException(statusCode: 403, code: 'unprovisioned', message: 'x')).title, 'Pano henüz hazırlanmamış');
      expect(map(const LocalApiException(statusCode: 403, code: 'already_provisioned', message: 'x')).title, 'Pano zaten hazırlanmış');
      expect(map(const LocalApiException(statusCode: 409, code: 'busy', message: 'x')).title, 'Pano şu anda meşgul');
      expect(map(const LocalApiException(statusCode: 400, code: 'bad_host', message: 'x')).title, 'Pano bu adresi reddetti');
      expect(map(const LocalApiException(statusCode: 0, code: 'timeout', message: 'x')).kind, SetupProblemKind.timeout);
      expect(map(LocalApiException.network()).kind, SetupProblemKind.deviceNetwork);
      expect(map(LocalApiException.notConfigured()).why, contains('adresi'));
      expect(map(LocalApiException.invalid('x')).kind, SetupProblemKind.validation);
      expect(map(LocalApiException.cancelled()).title, 'İşlem iptal edildi');
      // Wi-Fi adımında ağ ipucu kurulum ağını anlatır, diğer adımlarda ev ağını.
      expect(map(LocalApiException.network(), step: 5).todo, contains('kurulum ağına'));
      expect(map(LocalApiException.network(), step: 7).todo, contains('ev Wi-Fi ağında'));
    });

    test('yanlış pano, oturum bitişi, güvenli depo ve bilinmeyen hata: ham istisna metni asla gösterilmez', () {
      final wrong = map(const WrongDeviceException(expectedUid: 'AHBU-S3-AAA111', foundUid: 'AHBU-S3-BBB222'));
      expect(wrong.kind, SetupProblemKind.wrongDevice);
      expect(wrong.why, contains('AHBU-S3-BBB222'));
      expect(wrong.todo, contains('hiçbir bilgi gönderilmedi'));
      expect(map(const WrongDeviceException(expectedUid: 'A')).why, contains('bildirmedi'));
      expect(map(const SetupSessionExpiredException()).kind, SetupProblemKind.expired);
      expect(map(SecureStorageException('x')).title, 'Telefon güvenli depoya erişemedi');
      final unknown = map(StateError('GIZLI-IC-HATA-METNI'));
      expect(unknown.kind, SetupProblemKind.unknown);
      for (final text in <String>[unknown.title, unknown.why, unknown.todo]) {
        expect(text, isNot(contains('GIZLI-IC-HATA-METNI')));
        expect(text, isNot(contains('Exception')));
        expect(text, isNot(contains('Bad state')));
      }
    });

    test('hazır SetupProblemException olduğu gibi iletilir', () {
      const p = SetupProblem(kind: SetupProblemKind.validation, title: 't', why: 'w', todo: 'd', retryable: false, fixStep: 3);
      expect(map(const SetupProblemException(p)), same(p));
    });

    test('waitText süreyi insan diliyle yazar', () {
      expect(SetupProblems.waitText(null), 'kısa bir süre');
      expect(SetupProblems.waitText(Duration.zero), 'kısa bir süre');
      expect(SetupProblems.waitText(const Duration(milliseconds: 200)), '1 saniye');
      expect(SetupProblems.waitText(const Duration(seconds: 45)), '45 saniye');
      expect(SetupProblems.waitText(const Duration(seconds: 90)), '1 dakika');
      expect(SetupProblems.waitText(const Duration(minutes: 15)), '15 dakika');
    });
  });
}
