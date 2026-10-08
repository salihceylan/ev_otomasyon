import 'package:ev_otomasyon/services/alarm_watch/refresh_gate.dart';
import 'package:ev_otomasyon/services/api_exception.dart';
import 'package:ev_otomasyon/services/ev_cloud_api_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';

/// Ön plan uygulaması ile arka plan alarm izleyicisi AYNI oturum ailesini paylaşır: yenileme kapı altında ve depodaki en
/// son refresh token'la yapılmalı (eski token'ın yeniden kullanımı sunucuda bütün aileyi iptal eder, CONTRACTS §1.2).
class _RecordingGate implements RefreshGate {
  int runs = 0;
  bool inside = false;

  @override
  Future<T> run<T>(Future<T> Function() action) async {
    runs++;
    inside = true;
    try {
      return await action();
    } finally {
      inside = false;
    }
  }
}

void main() {
  late MockApi api;
  late EvCloudApiService service;
  late _RecordingGate gate;
  late List<String> sentTokens;

  setUp(() {
    api = MockApi();
    service = EvCloudApiService(baseUrl: 'https://api.test/api', client: api.client, clock: FakeClock())
      ..setAuthToken('access-old')
      ..setRefreshToken('refresh-memory');
    gate = _RecordingGate();
    sentTokens = <String>[];
    api.on('POST', '/api/v1/auth/refresh', (r) {
      sentTokens.add(r.json?['refresh_token'] as String);
      expect(gate.inside, isTrue, reason: 'yenileme kapı tutulurken');
      return okResponse(<String, dynamic>{'access_token': 'access-new', 'refresh_token': 'refresh-new'});
    });
  });

  tearDown(() => service.dispose());

  test('kapı yokken davranış aynı (bellekteki token)', () async {
    gate.inside = true; // kapı kullanılmıyor; iddiayı geçirmek için
    expect(await service.refreshSession(), isTrue);
    expect(sentTokens, <String>['refresh-memory']);
  });

  test('kapı varken: depodaki daha yeni token benimsenir, yenisi kalıcı yazımı beklenerek kapı içinde yazılır', () async {
    final persisted = <String>[];
    service
      ..refreshGate = gate
      ..readStoredRefreshToken = (() async => 'refresh-rotated-by-other-isolate')
      ..onTokenRefreshed = (access, refresh) async {
        expect(gate.inside, isTrue, reason: 'yazım kapı bırakılmadan önce');
        persisted.add(refresh!);
      };
    expect(await service.refreshSession(), isTrue);
    expect(sentTokens, <String>['refresh-rotated-by-other-isolate']);
    expect(persisted, <String>['refresh-new']);
    expect(service.currentRefreshToken, 'refresh-new');
    expect(gate.runs, 1);
  });

  test('ön plan: depo boş/okunamıyorsa bellekteki token ile sürer', () async {
    service
      ..refreshGate = gate
      ..readStoredRefreshToken = (() async => throw StateError('depo'));
    expect(await service.refreshSession(), isTrue);
    expect(sentTokens, <String>['refresh-memory']);
  });

  test('kalıcı yazım başarısız olduysa depodaki ESKİ token benimsenmez; bellekteki yenisiyle sürer', () async {
    // 1. yenileme: sunucu refresh-new verir, güvenli depoya yazım HATA verir -> depo hâlâ refresh-memory'dir.
    var storage = 'refresh-memory';
    service
      ..refreshGate = gate
      ..readStoredRefreshToken = (() async => storage)
      ..onTokenRefreshed = (access, refresh) async => throw StateError('depo yazılamadı');
    await service.refreshSession().catchError((_) => false);
    expect(service.currentRefreshToken, 'refresh-new');
    // 2. yenileme: depoyu başka kimse değiştirmedi (hâlâ refresh-memory). Eski (kullanılmış) token geri alınırsa sunucu
    // bütün oturum ailesini iptal ederdi; bellekteki refresh-new kullanılmalı.
    api.on('POST', '/api/v1/auth/refresh', (r) {
      sentTokens.add(r.json?['refresh_token'] as String);
      return okResponse(<String, dynamic>{'access_token': 'access-3', 'refresh_token': 'refresh-3'});
    });
    service.onTokenRefreshed = (access, refresh) async => storage = refresh!;
    expect(await service.refreshSession(), isTrue);
    expect(sentTokens.last, 'refresh-new');
  });

  test('uyelik-3: yazım hatasını kaydedip bildiren callback (AutomationState gibi): yenileme başarılı; ikinci yenileme '
      'bellekteki token\'ı gönderir (depodaki eski token benimsenmez)', () async {
    var storage = 'refresh-memory';
    final storageErrors = <String>[];
    service
      ..refreshGate = gate
      ..readStoredRefreshToken = (() async => storage)
      ..onTokenRefreshed = (access, refresh) async {
        try {
          throw StateError('depo yazılamadı');
        } catch (e) {
          storageErrors.add('$e'); // kullanıcıya storageError olarak gösterilir
          rethrow; // ... ve başarısızlık çağırana bildirilir
        }
      };
    expect(await service.refreshSession(), isTrue, reason: 'yazım hatası yenilemeyi başarısız saymaz');
    expect(service.currentRefreshToken, 'refresh-new');
    expect(storageErrors, hasLength(1));
    api.on('POST', '/api/v1/auth/refresh', (r) {
      sentTokens.add(r.json?['refresh_token'] as String);
      return okResponse(<String, dynamic>{'access_token': 'access-3', 'refresh_token': 'refresh-3'});
    });
    service.onTokenRefreshed = (access, refresh) async => storage = refresh!;
    expect(await service.refreshSession(), isTrue);
    expect(sentTokens, <String>['refresh-memory', 'refresh-new']);
  });

  test('uyelik-3: giriş (beginSession) sonrası depo durumu bilinmiyor: depodaki eski token benimsenmez; '
      'markRefreshPersisted sonrası kapılı benimseme yeniden çalışır', () async {
    var storage = 'refresh-onceki-oturum'; // giriş yazımı başarısız oldu: depoda eski oturumun token'ı kaldı
    service
      ..beginSession(accessToken: 'access-login', refreshToken: 'refresh-login')
      ..refreshGate = gate
      ..readStoredRefreshToken = (() async => storage)
      ..onTokenRefreshed = (access, refresh) async => storage = refresh!;
    expect(service.storedRefreshKnown, isFalse);
    expect(await service.refreshSession(), isTrue);
    expect(sentTokens, <String>['refresh-login'], reason: 'bilinmiyorken depodan benimseme yapılmaz');

    // Yeni giriş: yazım bitti (AutomationState bildirir); ardından arka plan servisi token'ı döndürdü.
    service.beginSession(accessToken: 'access-login-2', refreshToken: 'refresh-login-2');
    storage = 'refresh-login-2';
    service.markRefreshPersisted('refresh-login-2');
    expect(service.storedRefreshKnown, isTrue);
    storage = 'refresh-by-background';
    expect(await service.refreshSession(), isTrue);
    expect(sentTokens.last, 'refresh-by-background');
  });

  test('uyelik-3: markRefreshPersisted bellekteki token değilse (eski yazım) yok sayılır', () async {
    service.beginSession(accessToken: 'a', refreshToken: 'refresh-current');
    service.markRefreshPersisted('refresh-stale');
    expect(service.storedRefreshKnown, isFalse);
  });

  test('depoyu başka isolate döndürdüyse (son görülenden farklı) yenisi benimsenir', () async {
    var storage = 'refresh-memory';
    service
      ..refreshGate = gate
      ..readStoredRefreshToken = (() async => storage)
      ..onTokenRefreshed = (access, refresh) async => storage = refresh!;
    expect(await service.refreshSession(), isTrue); // refresh-memory -> refresh-new (depoya yazıldı)
    storage = 'refresh-by-background'; // arka plan servisi bu arada döndürdü
    api.on('POST', '/api/v1/auth/refresh', (r) {
      sentTokens.add(r.json?['refresh_token'] as String);
      return okResponse(<String, dynamic>{'access_token': 'access-3', 'refresh_token': 'refresh-3'});
    });
    expect(await service.refreshSession(), isTrue);
    expect(sentTokens, <String>['refresh-memory', 'refresh-by-background']);
  });

  group('uyelik-4: arka plan izleyicide ret sonrası depo yoklaması', () {
    late FakeClock clock;
    late MockApi local;
    late EvCloudApiService bg;
    late List<String> sent;
    late List<SessionEndReason> ended;
    var storage = '';

    setUp(() {
      clock = FakeClock();
      local = MockApi();
      sent = <String>[];
      ended = <SessionEndReason>[];
      storage = 'refresh-old';
      bg = EvCloudApiService(baseUrl: 'https://api.test/api', client: local.client, clock: clock)
        ..setAuthToken('access-old')
        ..setRefreshToken('refresh-old')
        ..refreshGate = _RecordingGate()
        ..storedSessionIsAuthoritative = true
        ..readStoredRefreshToken = (() async => storage)
        ..onTokenRefreshed = ((access, refresh) async => storage = refresh!)
        ..onSessionExpired = ended.add;
      local.on('POST', '/api/v1/auth/refresh', (r) {
        final token = r.json?['refresh_token'] as String;
        sent.add(token);
        if (token == 'refresh-old') return errorResponse(401, 'Oturum iptal edildi.', code: 'INVALID_TOKEN');
        return okResponse(<String, dynamic>{'access_token': 'access-after', 'refresh_token': 'refresh-after'});
      });
    });

    tearDown(() => bg.dispose());

    test('ret sonrası depoda (ön planın şifre değişimi) yeni token belirirse benimsenir ve bir kez daha denenir', () async {
      final future = bg.refreshSession();
      await clock.elapse(const Duration(seconds: 2));
      expect(ended, isEmpty, reason: 'ret hemen oturumu bitirmez');
      storage = 'refresh-from-foreground';
      await clock.elapse(const Duration(seconds: 1));
      expect(await future, isTrue);
      expect(sent, <String>['refresh-old', 'refresh-from-foreground']);
      expect(bg.currentRefreshToken, 'refresh-after');
      expect(storage, 'refresh-after');
      expect(ended, isEmpty);
    });

    test('depo 10 sn içinde değişmezse oturum biter', () async {
      final future = bg.refreshSession();
      await clock.elapse(const Duration(seconds: 11));
      expect(await future, isFalse);
      expect(sent, <String>['refresh-old']);
      expect(ended, hasLength(1));
      expect(bg.hasSession, isFalse);
    });
  });

  test('ön plan (depo yetkili değil): ret hemen oturumu bitirir (yoklama yok)', () async {
    final ended = <SessionEndReason>[];
    api.on('POST', '/api/v1/auth/refresh', (r) {
      sentTokens.add(r.json?['refresh_token'] as String);
      return errorResponse(401, 'x', code: 'INVALID_TOKEN');
    });
    gate.inside = true;
    service
      ..refreshGate = gate
      ..readStoredRefreshToken = (() async => 'refresh-memory')
      ..onSessionExpired = ended.add;
    expect(await service.refreshSession(), isFalse);
    expect(ended, hasLength(1));
  });

  test('arka plan: depo boşsa (çıkış yapılmış) yenileme YAPILMAZ ve oturum biter', () async {
    final expired = <SessionEndReason>[];
    service
      ..refreshGate = gate
      ..storedSessionIsAuthoritative = true
      ..readStoredRefreshToken = (() async => null)
      ..onSessionExpired = expired.add;
    expect(await service.refreshSession(), isFalse);
    expect(sentTokens, isEmpty);
    expect(expired, hasLength(1));
    expect(service.hasSession, isFalse);
  });
}
