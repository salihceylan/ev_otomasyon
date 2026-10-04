import 'dart:async';
import 'dart:convert';

import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/support.dart';

/// WP-BIO2 (B): "bir kere girince artık otomatik girsin" — saklı oturum, yenileme belirteci (30 gün, kaydırmalı)
/// geçerli olduğu sürece HER açılışta sessizce sürer. Kullanıcıyı giriş ekranına düşüren yalnız şunlardır:
/// kasıtlı çıkış, sunucunun yenileme belirtecini KALICI reddi (401), servis oturumunun 2 saatinin dolması.
///
/// * (f) ağ hatası / 5xx / 429'da yenileme başarısız olursa oturum KORUNUR (önbellek-önce ya da hata şeridi),
///   depo silinmez, oturum olayı üretilmez;
/// * (g) sunucu 401'de oturum olayı + yerel temizlik + giriş ekranı;
/// * bozuk kullanıcı kaydı + geçerli yenileme belirteci: silmek yerine yenile ve kullanıcıyı JWT'den türet;
/// * rotasyonda önce yeni yenileme belirteci yazılır (iki yazım arasında ölüm "yeniden kullanım" doğurmaz);
/// * olaysız `false` (savunma): açılış ekranında takılı kalmak yerine giriş ekranı, depo silinmez.
void main() {
  UserModel user(String id) => UserModel(id: id, email: '$id@example.test', fullName: 'Kullanıcı $id', role: 'user');

  Future<void> settle() => pumpEventQueue();

  String b64(Map<String, dynamic> m) => base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');

  /// Gerçek olmayan, biçimi geçerli (üç parça, base64url gövde) erişim JWT'si; imza doğrulanmaz.
  String jwtFor(String userId, {String role = 'user'}) =>
      '${b64(<String, dynamic>{'alg': 'none'})}.${b64(<String, dynamic>{'sub': userId, 'role': role})}.sig';

  FakeStorage withTokens({String? access = 'stored-access', String? refresh = 'stored-refresh', UserModel? stored}) {
    final storage = FakeStorage();
    if (access != null) storage.memory.data['ahbu_auth_token'] = access;
    if (refresh != null) storage.memory.data['ahbu_refresh_token'] = refresh;
    if (stored != null) storage.memory.data['ahbu_current_user'] = jsonEncode(stored.toJson());
    return storage;
  }

  FakeCloudApi cloudWithHomes() => FakeCloudApi()
    ..homes = <HomeModel>[testHome()]
    ..endpoints[kHomeA] = testEndpoints();

  StateHarness start({required FakeStorage storage, FakeCloudApi? cloud, FakeBiometric? biometric}) {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final h = StateHarness(autoInit: true, storage: storage, cloud: cloud ?? cloudWithHomes(), biometric: biometric);
    addTearDown(h.dispose);
    return h;
  }

  /// Sunucunun başarılı yenilemesi: yeni erişim (+ rotasyonla yeni yenileme) belirteci; kalıcı yazım beklenir.
  Future<bool> Function() refreshOk(FakeCloudApi cloud, {required String access, String refresh = 'yenilenen-refresh'}) {
    return () async {
      cloud.setAuthToken(access);
      cloud.setRefreshToken(refresh);
      await cloud.onTokenRefreshed?.call(access, refresh);
      return true;
    };
  }

  group('(f) yenileme belirteci varken ağ hatası: oturum korunur', () {
    test('yalnız refresh token + ağ hatası + önbellek yok: giriş ekranına DÜŞMEZ, depo silinmez, oturum olayı yok', () async {
      final storage = withTokens(access: null, stored: user('user-1'));
      final cloud = cloudWithHomes()
        ..fetchHomesError = ApiException.network()
        ..refreshHandler = (() async => throw ApiException.network());
      final h = start(storage: storage, cloud: cloud);
      final events = <SessionEvent>[];
      final sub = h.state.sessionEvents.listen(events.add);
      addTearDown(sub.cancel);
      await h.state.ready;
      await settle();

      expect(h.state.authStatus, AuthStatus.authenticated, reason: 'ağ hatası oturumu kapatmaz');
      expect(h.state.currentUser?.id, 'user-1');
      expect(h.state.homesError, isNotNull, reason: 'kullanıcı "evler yüklenemedi / yeniden dene" görür');
      expect(h.state.sessionNotice, isNull);
      expect(events, isEmpty);
      expect(storage.memory.data['ahbu_refresh_token'], 'stored-refresh', reason: 'belirteç SİLİNMEZ');
      expect(cloud.currentRefreshToken, 'stored-refresh', reason: 'istemci de belirteci korur: ilk 401 yeniden dener');
      expect(cloud.count('refreshSession'), 1);
    });

    test('ağ gelince yeniden deneme oturumu tamamlar: yenileme + ev listesi; yeniden giriş gerekmez', () async {
      final storage = withTokens(access: null, stored: user('user-1'));
      final cloud = cloudWithHomes()
        ..fetchHomesError = ApiException.network()
        ..refreshHandler = (() async => throw ApiException.network());
      final h = start(storage: storage, cloud: cloud);
      await h.state.ready;
      await settle();
      expect(h.state.homes, isEmpty, reason: 'hazırlık: çevrimdışı');

      cloud.fetchHomesError = null;
      cloud.refreshHandler = refreshOk(cloud, access: 'yenilenen-access');
      expect(await cloud.refreshSession(), isTrue, reason: 'ilk 401 yolunun tek-uçuş yenilemesi (modellendi)');
      await h.state.fetchHomes();
      await settle();

      expect(h.state.authStatus, AuthStatus.authenticated);
      expect(h.state.homesLoaded, isTrue);
      expect(h.state.activeHome?.id, kHomeA);
      expect(await storage.getAuthToken(), 'yenilenen-access');
      expect(await storage.getRefreshToken(), 'yenilenen-refresh', reason: 'rotasyonla gelen yeni belirteç saklanır');
    });

    test('yalnız refresh token + ağ hatası + ÖNBELLEK var: pano önbellekle (çevrimdışı) açılır', () async {
      final storage = withTokens(access: null, stored: user('user-1'));
      await storage.saveHomesCache('user-1', <HomeModel>[testHome()]);
      final cloud = cloudWithHomes()
        ..fetchHomesError = ApiException.network()
        ..refreshHandler = (() async => throw ApiException.network());
      final h = start(storage: storage, cloud: cloud);
      await h.state.ready;
      await settle();

      expect(h.state.authStatus, AuthStatus.authenticated);
      expect(h.state.homes.map((e) => e.id), <String>[kHomeA]);
      expect(h.state.homesFromCache, isTrue);
      expect(h.state.activeHome?.id, kHomeA);
      expect(storage.memory.data['ahbu_refresh_token'], 'stored-refresh');
    });

    test('yenileme 5xx (geçici sunucu hatası): oturum korunur, depo silinmez', () async {
      final storage = withTokens(access: null, stored: user('user-1'));
      final cloud = cloudWithHomes()
        ..refreshHandler = (() async => throw const ApiException(
              statusCode: 503,
              code: 'SERVICE_UNAVAILABLE',
              message: 'Sunucu şu anda yanıt veremiyor.',
            ));
      final h = start(storage: storage, cloud: cloud);
      final events = <SessionEvent>[];
      final sub = h.state.sessionEvents.listen(events.add);
      addTearDown(sub.cancel);
      await h.state.ready;
      await settle();

      expect(h.state.authStatus, AuthStatus.authenticated);
      expect(events, isEmpty);
      expect(storage.memory.data['ahbu_refresh_token'], 'stored-refresh');
    });

    test('süresi dolmuş erişim belirteci + geçerli refresh: açılış sessizce sürer (ilk 401 tek-uçuş yeniler)', () async {
      // Saklı erişim belirteci kullanılır; ev listesi gelir. (Gerçek istemcide ilk 401 `_refreshSingleFlight` ile
      // yenilenir ve istek bir kez yinelenir: bkz. ev_cloud_api_auth_test "401 TOKEN_EXPIRED".)
      final storage = withTokens(stored: user('user-1'));
      final h = start(storage: storage);
      await h.state.ready;
      await settle();

      expect(h.state.authStatus, AuthStatus.authenticated);
      expect(h.cloud.count('refreshSession'), 0, reason: 'erişim belirteci varken önden yenileme yapılmaz');
      expect(h.state.activeHome?.id, kHomeA);
    });
  });

  group('(g) sunucunun kalıcı reddi: çıkış', () {
    test('yenileme 401 (oturum olayı): giriş ekranı, depo temiz, bildirim', () async {
      final storage = withTokens(access: null, stored: user('user-1'));
      final cloud = cloudWithHomes();
      cloud.refreshHandler = () async {
        cloud.clearSession();
        cloud.onSessionExpired?.call(SessionEndReason.refreshRejected);
        return false;
      };
      final h = start(storage: storage, cloud: cloud);
      final events = <SessionEvent>[];
      final sub = h.state.sessionEvents.listen(events.add);
      addTearDown(sub.cancel);
      await h.state.ready;
      await settle();

      expect(h.state.authStatus, AuthStatus.unauthenticated);
      expect(events.whereType<SessionExpiredEvent>(), hasLength(1));
      expect(h.state.sessionNotice, contains('tekrar giriş'));
      expect(storage.isEmpty, isTrue);
      expect(h.cloud.count('fetchHomes'), 0);
    });

    test('gerçek istemci yolu: sunucu yenilemeyi reddeder (sahte HTTP 404 -> kalıcı red): giriş ekranı, depo temiz', () async {
      final storage = withTokens(access: null, stored: user('user-1'));
      final h = start(storage: storage); // refreshHandler yok: gerçek `_doRefresh` + MockClient 404
      final events = <SessionEvent>[];
      final sub = h.state.sessionEvents.listen(events.add);
      addTearDown(sub.cancel);
      await h.state.ready;
      await settle();

      expect(h.state.authStatus, AuthStatus.unauthenticated);
      expect(events.whereType<SessionExpiredEvent>(), hasLength(1));
      expect(storage.isEmpty, isTrue);
      expect(h.cloud.hasSession, isFalse);
    });

    test('olaysız `false` (savunma): açılış ekranında takılı kalmaz -> giriş ekranı; saklı belirteçler SİLİNMEZ', () async {
      final storage = withTokens(access: null, stored: user('user-1'));
      final cloud = cloudWithHomes()..refreshHandler = (() async => false);
      final h = start(storage: storage, cloud: cloud);
      final events = <SessionEvent>[];
      final sub = h.state.sessionEvents.listen(events.add);
      addTearDown(sub.cancel);
      await h.state.ready;
      await settle();

      expect(h.state.authStatus, AuthStatus.unauthenticated, reason: 'eskiden: sonsuza dek "checking" (açılış ekranı)');
      expect(events, isEmpty);
      expect(storage.memory.data['ahbu_refresh_token'], 'stored-refresh');
      expect(h.cloud.count('fetchHomes'), 0);
    });
  });

  group('bozuk kullanıcı kaydı + geçerli yenileme belirteci (silme yerine yenile)', () {
    test('kayıt yok, erişim belirteci opak, refresh var: oturum SİLİNMEZ; yenileme -> kullanıcı JWT\'den türetilir, kayıt onarılır', () async {
      final storage = withTokens(access: 'opak-belirtec', refresh: 'stored-refresh');
      final cloud = cloudWithHomes();
      cloud.refreshHandler = refreshOk(cloud, access: jwtFor('user-9'));
      final h = start(storage: storage, cloud: cloud);
      final events = <SessionEvent>[];
      final sub = h.state.sessionEvents.listen(events.add);
      addTearDown(sub.cancel);
      await h.state.ready;
      await settle();

      expect(h.state.authStatus, AuthStatus.authenticated, reason: 'eskiden: bozuk kayıt sayılıp silinir, giriş ekranı');
      expect(h.state.currentUser?.id, 'user-9');
      expect(events, isEmpty);
      expect(cloud.calls.indexOf('refreshSession'), lessThan(cloud.calls.indexOf('fetchHomes')),
          reason: 'çözülemeyen erişim belirteci kullanılmaz: önce yenileme');
      expect(h.state.activeHome?.id, kHomeA);
      expect((await storage.getUser())?.id, 'user-9', reason: 'kayıt onarıldı: sonraki açılış normal yoldan geri yükler');
      expect(await storage.getRefreshToken(), 'yenilenen-refresh');
      expect(await storage.getAuthToken(), jwtFor('user-9'));
    });

    test('aynı durumda ağ hatası: kullanıcısız oturum KURULMAZ (giriş ekranı) ama belirteçler SİLİNMEZ', () async {
      final storage = withTokens(access: 'opak-belirtec', refresh: 'stored-refresh');
      final cloud = cloudWithHomes()..refreshHandler = (() async => throw ApiException.network());
      final h = start(storage: storage, cloud: cloud);
      final events = <SessionEvent>[];
      final sub = h.state.sessionEvents.listen(events.add);
      addTearDown(sub.cancel);
      await h.state.ready;
      await settle();

      expect(h.state.authStatus, AuthStatus.unauthenticated);
      expect(h.state.currentUser, isNull, reason: '"authenticated" + kullanıcı yok olmaz');
      expect(events, isEmpty);
      expect(h.state.sessionNotice, isNull);
      expect(storage.memory.data['ahbu_refresh_token'], 'stored-refresh', reason: 'ağ gelince sonraki açılış dener');
      expect(h.cloud.hasSession, isFalse, reason: 'bellekte yarım oturum kalmaz');
      expect(h.cloud.count('fetchHomes'), 0);
    });

    test('aynı durumda sunucu reddi: oturum olayı + depo temiz (bozuk kayıt temizlenmiş olur)', () async {
      final storage = withTokens(access: 'opak-belirtec', refresh: 'stored-refresh');
      final h = start(storage: storage); // gerçek `_doRefresh` + MockClient 404 -> kalıcı red
      final events = <SessionEvent>[];
      final sub = h.state.sessionEvents.listen(events.add);
      addTearDown(sub.cancel);
      await h.state.ready;
      await settle();

      expect(h.state.authStatus, AuthStatus.unauthenticated);
      expect(events.whereType<SessionExpiredEvent>(), hasLength(1));
      expect(storage.isEmpty, isTrue);
      expect(h.cloud.hasSession, isFalse);
    });

    test('kayıt yok, erişim opak ve refresh de YOK: kurtarılamaz, bozuk kayıt temizlenir (değişmedi)', () async {
      final storage = withTokens(access: 'opak-belirtec', refresh: null);
      final h = start(storage: storage);
      await h.state.ready;
      await settle();

      expect(h.state.authStatus, AuthStatus.unauthenticated);
      expect(storage.isEmpty, isTrue);
      expect(h.cloud.hasSession, isFalse);
      expect(h.cloud.count('refreshSession'), 0);
    });

    test('biyometrik kilit + bozuk kayıt: kilit açılınca yenileme ve kullanıcı türetme (kilit atlanmaz)', () async {
      final storage = withTokens(access: 'opak-belirtec', refresh: 'stored-refresh');
      storage.memory.data['ahbu_biometric_enabled'] = 'true';
      final cloud = cloudWithHomes();
      cloud.refreshHandler = refreshOk(cloud, access: jwtFor('user-9'));
      final biometric = FakeBiometric(supported: true)..pending = Completer<bool>();
      final h = start(storage: storage, cloud: cloud, biometric: biometric);
      await settle();

      expect(h.state.authStatus, AuthStatus.checking);
      expect(cloud.calls, isEmpty, reason: 'kilitliyken yenileme dahil ağ çağrısı yok');
      expect(storage.memory.data['ahbu_refresh_token'], 'stored-refresh');

      biometric.pending!.complete(true);
      await h.state.ready;
      await settle();

      expect(h.state.authStatus, AuthStatus.authenticated);
      expect(h.state.currentUser?.id, 'user-9');
      expect(h.state.activeHome?.id, kHomeA);
    });

    test('kayıt yok ama erişim belirteci JWT: türetme yeterli, önden yenileme yapılmaz (değişmedi)', () async {
      final storage = withTokens(access: jwtFor('user-9'), refresh: 'stored-refresh');
      final h = start(storage: storage);
      await h.state.ready;
      await settle();

      expect(h.state.authStatus, AuthStatus.authenticated);
      expect(h.state.currentUser?.id, 'user-9');
      expect(h.cloud.count('refreshSession'), 0);
    });
  });

  group('rotasyon: yenilenen belirteçlerin yazım sırası', () {
    test('ÖNCE yeni yenileme belirteci, SONRA erişim belirteci yazılır (iki yazım arasında ölüm: eski refresh kalmaz)', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      final store = h.storage.memory;
      store.hangWrites = Completer<void>(); // ilk yazım platformda askıda: hangisi önce başladı?
      final refreshWritesBefore = store.writeCountFor('ahbu_refresh_token');
      final accessWritesBefore = store.writeCountFor('ahbu_auth_token');

      final persisted = h.cloud.onTokenRefreshed!('yeni-access', 'yeni-refresh');
      await settle();

      expect(store.writeCountFor('ahbu_refresh_token'), refreshWritesBefore + 1, reason: 'yenileme belirteci ilk yazılır');
      expect(store.writeCountFor('ahbu_auth_token'), accessWritesBefore, reason: 'erişim belirteci yenileme yazılmadan başlamaz');

      store.hangWrites!.complete();
      await persisted;
      await settle();
      expect(await h.storage.getRefreshToken(), 'yeni-refresh');
      expect(await h.storage.getAuthToken(), 'yeni-access');
    });

    test('yenileme yanıtı yeni refresh token taşımıyorsa eskisi korunur (yalnız erişim yazılır)', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      await h.state.login('a@b.c', 'parola-1234');
      await settle();
      expect(await h.storage.getRefreshToken(), 'refresh-1', reason: 'hazırlık');

      await h.cloud.onTokenRefreshed!('yeni-access', null);
      await settle();

      expect(await h.storage.getAuthToken(), 'yeni-access');
      expect(await h.storage.getRefreshToken(), 'refresh-1');
    });
  });
}
