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
