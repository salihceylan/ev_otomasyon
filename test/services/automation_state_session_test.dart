import 'dart:async';
import 'dart:convert';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/support.dart';

/// Oturum yaşam döngüsü: giriş/çıkış, hesap değiştirme, `fetchHomes` hata ayrımı, oturum olayları,
/// servis PIN oturumu, biyometrik kilit, uygulama yaşam döngüsü ve başlangıçta oturum geri yükleme.
void main() {
  UserModel user(String id, {bool mustChange = false, String role = 'user'}) => UserModel(
        id: id,
        email: '$id@example.test',
        fullName: 'Kullanıcı $id',
        role: role,
        mustChangePassword: mustChange,
      );

  /// Giriş yapılmamış, ev verisi hazır bir donanım.
  StateHarness loggedOutHarness() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final h = StateHarness();
    h.cloud.homes = <HomeModel>[testHome()];
    h.cloud.endpoints[kHomeA] = testEndpoints();
    h.cloud.devicesByHome[kHomeA] = <DeviceInfo>[
      const DeviceInfo(deviceUuid: 'AHBU-S3-TEST01', name: 'Pano', online: true, firmware: '1.1.0'),
    ];
    return h;
  }

  Future<void> settle() => pumpEventQueue();

  group('giriş', () {
    test('login: belirteçler yalnızca güvenli depoda; ev listesi yüklenir; tercihlerde belirteç yok', () async {
      final h = loggedOutHarness();
      final ok = await h.state.login('a@b.c', 'parola-1234');
      await settle();

      expect(ok, isTrue);
      expect(h.state.authStatus, AuthStatus.authenticated);
      expect(h.state.currentUser?.id, 'user-1');
      expect(h.state.homesLoaded, isTrue);
      expect(h.state.activeHome?.id, kHomeA);
      expect(await h.storage.getAuthToken(), 'access-1');
      expect(await h.storage.getRefreshToken(), 'refresh-1');
      expect((await h.storage.getUser())?.id, 'user-1');

      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys()) {
        final value = prefs.get(key).toString();
        expect(value, isNot(contains('access-1')), reason: key);
        expect(value, isNot(contains('refresh-1')), reason: key);
      }
      h.dispose();
    });

    test('hatalı giriş: oturum açılmaz, ApiException fırlatılır, depoya bir şey yazılmaz', () async {
      final h = loggedOutHarness();
      h.cloud.loginError = const ApiException(
        statusCode: 401,
        code: 'INVALID_CREDENTIALS',
        message: 'Geçersiz e-posta / telefon veya şifre.',
      );
      await expectLater(
        h.state.login('a@b.c', 'yanlis'),
        throwsA(isA<ApiException>().having((e) => e.isInvalidCredentials, 'isInvalidCredentials', isTrue)),
      );
      await settle();
      expect(h.state.isAuthenticated, isFalse);
      expect(h.storage.isEmpty, isTrue);
      h.dispose();
    });

    test('sihirli bağlantı girişi: oturum açılır (token POST ile gider, durum yazılır)', () async {
      final h = loggedOutHarness();
      final ok = await h.state.loginWithMagicLink('opaque-token-0123456789');
      await settle();
      expect(ok, isTrue);
      expect(h.cloud.count('magicLogin'), 1);
      expect(h.state.isAuthenticated, isTrue);
      expect(await h.storage.getRefreshToken(), 'refresh-1');
      h.dispose();
    });
  });

  group('zorunlu parola değişimi ve parola değiştirme', () {
    test('must_change_password: giriş yanıtından okunur ve kalıcılaşır', () async {
      final h = loggedOutHarness();
      h.cloud.loginUser = user('user-1', mustChange: true);
      await h.state.login('a@b.c', 'parola-1234');
      await settle();

      expect(h.state.mustChangePassword, isTrue);
      expect(h.state.currentUser?.mustChangePassword, isTrue);
      expect((await h.storage.getUser())?.mustChangePassword, isTrue);
      h.dispose();
    });

    test('changePassword: yeni belirteçler yazılır, bayrak kalkar, yerel veri ve canlı bağlantı korunur', () async {
      final h = loggedOutHarness();
      h.cloud.loginUser = user('user-1', mustChange: true);
      await h.state.login('a@b.c', 'eski-parola-12');
      await settle();
      final startCount = h.mqtt.startCount;
      final stopCount = h.mqtt.stopCount;
      final endpointCount = h.state.cloudEndpoints.length;

      await h.state.changePassword(currentPassword: 'eski-parola-12', newPassword: 'yeni-parola-34');

      expect(h.cloud.count('changePassword'), 1);
      expect(h.state.mustChangePassword, isFalse);
      expect(h.state.isAuthenticated, isTrue);
      expect(await h.storage.getAuthToken(), 'access-2');
      expect(await h.storage.getRefreshToken(), 'refresh-2');
      expect((await h.storage.getUser())?.mustChangePassword, isFalse);
      // Oturum aynı kullanıcı: ev, uç noktalar ve MQTT dokunulmadan kalır.
      expect(h.state.activeHome?.id, kHomeA);
      expect(h.state.cloudEndpoints.length, endpointCount);
      expect(h.mqtt.startCount, startCount);
      expect(h.mqtt.stopCount, stopCount);
      // İptal edilmiş eski refresh token için ayrıca sunucu çağrısı yapılmaz.
      expect(h.cloud.count('revokeRefreshToken'), 0);
      h.dispose();
    });

    test('changePassword: yanlış mevcut parola -> hata; bayrak ve belirteçler değişmez', () async {
      final h = loggedOutHarness();
      h.cloud.loginUser = user('user-1', mustChange: true);
      await h.state.login('a@b.c', 'eski-parola-12');
      await settle();
      h.cloud.changePasswordError = const ApiException(
        statusCode: 400,
        code: 'INVALID_CREDENTIALS',
        message: 'Mevcut şifre hatalı.',
      );

      await expectLater(
        h.state.changePassword(currentPassword: 'yanlis-parola', newPassword: 'yeni-parola-34'),
        throwsA(isA<ApiException>().having((e) => e.isInvalidCredentials, 'invalid', isTrue)),
      );
      expect(h.state.mustChangePassword, isTrue);
      expect(h.state.isAuthenticated, isTrue);
      expect(await h.storage.getAuthToken(), 'access-1');
      expect(await h.storage.getRefreshToken(), 'refresh-1');
      h.dispose();
    });

    test('changePassword: boş / aynı parola ağa gitmeden reddedilir', () async {
      final h = await readyHarness();
      await expectLater(
        h.state.changePassword(currentPassword: '', newPassword: 'yeni-parola-34'),
        throwsA(isA<ApiException>().having((e) => e.isValidation, 'validation', isTrue)),
      );
      await expectLater(
        h.state.changePassword(currentPassword: 'ayni-parola-12', newPassword: 'ayni-parola-12'),
        throwsA(isA<ApiException>().having((e) => e.isValidation, 'validation', isTrue)),
      );
      await expectLater(
        h.state.changePassword(currentPassword: 'eski-parola-12', newPassword: ''),
        throwsA(isA<ApiException>().having((e) => e.isValidation, 'validation', isTrue)),
      );
      expect(h.cloud.count('changePassword'), 0);
      h.dispose();
    });

    test('changePassword: servis PIN oturumu ve oturumsuz kullanıcı reddedilir', () async {
      final session = await readyHarness(globalRole: 'service_session', role: 'service_session');
      await expectLater(
        session.state.changePassword(currentPassword: 'a-parola-1234', newPassword: 'b-parola-5678'),
        throwsA(isA<ApiException>().having((e) => e.isForbidden, 'forbidden', isTrue)),
      );
      session.dispose();

      final anonymous = loggedOutHarness();
      await expectLater(
        anonymous.state.changePassword(currentPassword: 'a-parola-1234', newPassword: 'b-parola-5678'),
        throwsA(isA<ApiException>().having((e) => e.isForbidden, 'forbidden', isTrue)),
      );
      expect(anonymous.cloud.count('changePassword'), 0);
      anonymous.dispose();
    });

    test('changePassword sırasında oturum kapanırsa yeni belirteçler diske yazılmaz', () async {
      final h = loggedOutHarness();
      await h.state.login('a@b.c', 'eski-parola-12');
      await settle();

      // changePassword API çağrısı tamamlandığında (yeni belirteçler elde) kullanıcı çıkış yapmış olsun.
      h.cloud.changePasswordError = null;
      final pending = h.state.changePassword(currentPassword: 'eski-parola-12', newPassword: 'yeni-parola-34');
      await h.state.logout();
      await pending;
      await settle();
      expect(h.state.isAuthenticated, isFalse);
      expect(h.storage.isEmpty, isTrue, reason: 'çıkıştan sonra eski oturum belirteç yazamaz');
      h.dispose();
    });

    test('logoutAll: sunucu iptali başarılıysa yerel çıkış yapılır; ayrıca refresh iptali denenmez', () async {
      final h = loggedOutHarness();
      await h.state.login('a@b.c', 'parola-1234');
      await settle();

      await h.state.logoutAll();
      await settle();

      expect(h.cloud.count('logoutAll'), 1);
      expect(h.cloud.count('revokeRefreshToken'), 0);
      expect(h.state.authStatus, AuthStatus.unauthenticated);
      expect(h.state.currentUser, isNull);
      expect(h.storage.isEmpty, isTrue);
      h.dispose();
    });

    test('logoutAll: ağ hatasında ÇIKIŞ YAPILMAZ (kullanıcı işlemin olmadığını bilir)', () async {
      final h = loggedOutHarness();
      await h.state.login('a@b.c', 'parola-1234');
      await settle();
      h.cloud.logoutAllError = ApiException.network();

      await expectLater(
        h.state.logoutAll(),
        throwsA(isA<ApiException>().having((e) => e.isNetwork, 'isNetwork', isTrue)),
      );
      await settle();
      expect(h.state.isAuthenticated, isTrue);
      expect(await h.storage.getAuthToken(), 'access-1');
      expect(await h.storage.getRefreshToken(), 'refresh-1');
      h.dispose();
    });

    test('logoutAll: servis PIN oturumunda yalnızca yerel çıkış (sunucuya logout-all gitmez)', () async {
      final h = await readyHarness(globalRole: 'service_session', role: 'service_session');
      await h.state.logoutAll();
      expect(h.cloud.count('logoutAll'), 0);
      expect(h.state.isAuthenticated, isFalse);
      h.dispose();
    });
  });

  group('çıkış izolasyonu ve hesap değiştirme', () {
    test('logout: tüm kullanıcı kapsamlı alanlar, zamanlayıcılar, MQTT ve depo temizlenir', () async {
      final h = loggedOutHarness();
      await h.state.login('a@b.c', 'parola-1234');
      await settle();
      await h.state.generateServicePin();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('saved_service_device_uuid', 'AHBU-S3-TEST01');
      await prefs.setString('saved_service_device_ip', '192.168.1.30');
      await prefs.setString('saved_service_device_name', 'Pano');
      await prefs.setString('saved_esp_host', '192.168.1.30');
      await prefs.setString('saved_app_mode', 'direct');
      expect(h.state.servicePin, isNotNull);
      expect(h.mqtt.isConnected, isTrue);

      await h.state.logout();
      await settle();

      expect(h.state.authStatus, AuthStatus.unauthenticated);
      expect(h.state.currentUser, isNull);
      expect(h.state.homes, isEmpty);
      expect(h.state.activeHome, isNull);
      expect(h.state.cloudEndpoints, isEmpty);
      expect(h.state.devices, isEmpty);
      expect(h.state.scheduledRules, isEmpty);
      expect(h.state.servicePin, isNull);
      expect(h.state.servicePinExpiry, isNull);
      expect(h.state.peaceNotificationData, isNull);
      expect(h.state.childLockStatus, ChildLockStatus.unknown);
      expect(h.state.selectedDeviceUuid, isEmpty);
      expect(h.state.host, isEmpty);
      expect(h.mqtt.isConnected, isFalse);
      expect(h.mqtt.stopCount, greaterThan(0));
      expect(h.storage.isEmpty, isTrue);
      expect(h.clock.activeTimerCount, 0, reason: 'çıkıştan sonra canlı zamanlayıcı kalmamalı');
      for (final key in <String>[
        'saved_service_device_uuid',
        'saved_service_device_ip',
        'saved_service_device_name',
        'saved_esp_host',
        'saved_app_mode',
        'saved_active_home_id',
      ]) {
        expect(prefs.containsKey(key), isFalse, reason: '$key çıkışta silinmeli');
      }
      h.dispose();
    });

    test('logout: önce yerel temizlik, SONRA sunucuda refresh iptali (ağ hatası çıkışı engellemez)', () async {
      final h = loggedOutHarness();
      await h.state.login('a@b.c', 'parola-1234');
      await settle();
      AuthStatus? statusAtRevoke;
      bool? storageEmptyAtRevoke;
      h.cloud.onRevoke = (_) {
        statusAtRevoke = h.state.authStatus;
        storageEmptyAtRevoke = h.storage.isEmpty;
      };

      await h.state.logout();
      await settle();

      expect(h.cloud.revokedRefreshTokens, <String>['refresh-1']);
      expect(statusAtRevoke, AuthStatus.unauthenticated);
      expect(storageEmptyAtRevoke, isTrue);
      h.dispose();
    });

    test('hesap değiştirme: önceki kullanıcının hiçbir verisi kalmaz; önceki refresh token iptal edilir', () async {
      final h = loggedOutHarness();
      await h.state.login('a@b.c', 'parola-1234');
      await settle();
      expect(h.state.activeHome?.id, kHomeA);
      await h.storage.saveHomesCache('user-1', <HomeModel>[testHome()]);

      h.cloud.loginUser = user('user-2');
      h.cloud.homes = <HomeModel>[testHome(id: kHomeB, name: 'Ev B', topic: 'h_b')];
      h.cloud.endpoints[kHomeB] = testEndpoints(homeId: kHomeB);
      h.cloud.devicesByHome[kHomeB] = const <DeviceInfo>[
        DeviceInfo(deviceUuid: 'AHBU-S3-TEST02', name: 'Pano B', online: true),
      ];
      await h.state.login('b@b.c', 'parola-5678');
      await settle();

      expect(h.state.currentUser?.id, 'user-2');
      expect(h.state.homes.map((e) => e.id), <String>[kHomeB]);
      expect(h.state.activeHome?.id, kHomeB);
      expect(h.state.cloudEndpoints, isNotEmpty);
      expect(h.state.cloudEndpoints.every((e) => e.homeId == kHomeB), isTrue);
      expect(h.state.devices.map((d) => d.deviceUuid), <String>['AHBU-S3-TEST02']);
      expect(h.cloud.revokedRefreshTokens, contains('refresh-1'));
      expect((await h.storage.getUser())?.id, 'user-2');
      expect(await h.storage.loadHomesCache('user-1'), isEmpty);
      h.dispose();
    });

    test('bayat ev listesi yanıtı: çıkış + başka kullanıcı girişi sonrası yeni kullanıcının listesini ezmez', () async {
      final h = await readyHarness();
      final gate = Completer<void>();
      h.cloud.fetchHomesGate = gate;
      final stale = h.state.fetchHomes(); // eski kullanıcı için uçuşta (A evi)
      h.cloud.fetchHomesGate = null;

      await h.state.logout();
      h.cloud.loginUser = user('user-2');
      h.cloud.homes = <HomeModel>[testHome(id: kHomeB, name: 'Ev B', topic: 'h_b')];
      h.cloud.endpoints[kHomeB] = testEndpoints(homeId: kHomeB);
      await h.state.login('b@b.c', 'parola-5678');
      await settle();

      gate.complete();
      await stale;
      await settle();

      expect(h.state.currentUser?.id, 'user-2');
      expect(h.state.homes.map((e) => e.id), <String>[kHomeB]);
      expect(h.state.activeHome?.id, kHomeB);
      h.dispose();
    });
  });

  group('fetchHomes hata ayrımı', () {
    test('başarılı boş liste: yüklendi + hata yok ("ev yok" ile "hata" karışmaz)', () async {
      final h = await readyHarness(configure: (h) => h.cloud.homes = <HomeModel>[]);
      expect(h.state.homesLoaded, isTrue);
      expect(h.state.homesError, isNull);
      expect(h.state.homes, isEmpty);
      expect(h.state.activeHome, isNull);
      h.dispose();
    });

    test('ağ hatası + önbellek yok: hata mesajı, yüklenmedi, oturum korunur', () async {
      final h = await readyHarness(configure: (h) => h.cloud.fetchHomesError = ApiException.network());
      expect(h.state.homesLoaded, isFalse);
      expect(h.state.homesError, isNotNull);
      expect(h.state.homes, isEmpty);
      expect(h.state.isAuthenticated, isTrue, reason: 'ağ hatası oturumu düşürmez');
      h.dispose();
    });

    test('ağ hatası + önbellek var: önbellekteki evler gösterilir ve işaretlenir', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final h = StateHarness();
      h.cloud.endpoints[kHomeA] = testEndpoints();
      h.state
        ..setCurrentUserForTesting(user('user-1'))
        ..setAuthStatusForTesting(AuthStatus.authenticated);
      await h.storage.saveHomesCache('user-1', <HomeModel>[testHome()]);
      h.cloud.fetchHomesError = ApiException.network();

      await h.state.fetchHomes();
      await settle();

      expect(h.state.homesFromCache, isTrue);
      expect(h.state.homesError, isNotNull);
      expect(h.state.homes.map((e) => e.id), <String>[kHomeA]);
      expect(h.state.isAuthenticated, isTrue);
      h.dispose();
    });

    test('önbellek başka kullanıcıya aitse kullanılmaz', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final h = StateHarness();
      h.state
        ..setCurrentUserForTesting(user('user-2'))
        ..setAuthStatusForTesting(AuthStatus.authenticated);
      await h.storage.saveHomesCache('user-1', <HomeModel>[testHome()]);
      h.cloud.fetchHomesError = ApiException.network();

      await h.state.fetchHomes();
      expect(h.state.homes, isEmpty);
      expect(h.state.homesFromCache, isFalse);
      h.dispose();
    });

    test('5xx: genel mesaj (iç ayrıntı sızmaz), oturum korunur, ev listesi boşalmaz', () async {
      final h = await readyHarness();
      expect(h.state.homes, isNotEmpty);
      h.cloud.fetchHomesError = const ApiException(
        statusCode: 500,
        code: 'INTERNAL',
        message: 'Sunucu şu anda yanıt veremiyor. Lütfen daha sonra tekrar deneyin.',
      );
      await h.state.fetchHomes(autoSelect: false);
      expect(h.state.homesError, contains('Sunucu'));
      expect(h.state.homes, isNotEmpty, reason: 'geçici hata mevcut listeyi silmez');
      expect(h.state.isAuthenticated, isTrue);
      h.dispose();
    });

    test('401: hata mesajı yazılmaz (oturum kapatma olayı tek merkezden işlenir)', () async {
      final h = await readyHarness();
      h.cloud.fetchHomesError = const ApiException(
        statusCode: 401,
        code: 'INVALID_TOKEN',
        message: 'Oturumunuz sona erdi.',
      );
      await h.state.fetchHomes(autoSelect: false);
      expect(h.state.homesError, isNull);
      h.dispose();
    });

    test('rol değişimi: sunucu aynı evi başka rolle döndürürse yetkiler güncellenir', () async {
      final h = await readyHarness(role: 'owner');
      expect(h.state.capabilities.canInvite, isTrue);
      expect(h.state.capabilities.canTransferOwnership, isTrue);

      h.cloud.homes = <HomeModel>[testHome(role: 'resident')];
      await h.state.fetchHomes(autoSelect: false);
      await settle();

      expect(h.state.activeHome?.role, 'resident');
      expect(h.state.capabilities.canInvite, isFalse);
      expect(h.state.capabilities.canTransferOwnership, isFalse);
      expect(h.state.capabilities.canControlDevices, isTrue);
      h.dispose();
    });

    test('aktif ev listeden kalkarsa (üyelik/devir) ev verisi ve canlı bağlantı kapatılır', () async {
      final h = await readyHarness();
      expect(h.state.cloudEndpoints, isNotEmpty);
      final stops = h.mqtt.stopCount;

      h.cloud.homes = <HomeModel>[];
      await h.state.fetchHomes(autoSelect: false);
      await settle();

      expect(h.state.activeHome, isNull);
      expect(h.state.cloudEndpoints, isEmpty);
      expect(h.mqtt.stopCount, greaterThan(stops));
      h.dispose();
    });

    test('erişim durumu (`access_state`) süresi dolmuş gelirse veri kapatılır ve misafir yetkisi kalkar', () async {
      final now = h0Now();
      final h = await readyHarness(
        home: HomeModel(
          id: kHomeA,
          name: 'Ev A',
          role: 'guest',
          mqttTopicId: 'h_test',
          guestValidFrom: now.subtract(const Duration(hours: 1)),
          guestValidUntil: now.add(const Duration(hours: 5)),
          accessState: HomeAccessState.active,
        ),
      );
      expect(h.state.capabilities.isGuest, isTrue);
      expect(h.state.cloudEndpoints, isNotEmpty);

      // Sunucu: erişim bitti (ör. ev sahibi süreyi kısalttı); pencere alanları hâlâ gelecekte görünüyor.
      h.cloud.homes = <HomeModel>[
        HomeModel(
          id: kHomeA,
          name: 'Ev A',
          role: 'guest',
          mqttTopicId: '',
          guestValidFrom: now.subtract(const Duration(hours: 1)),
          guestValidUntil: now.add(const Duration(hours: 5)),
          serverMarkedExpired: true,
          accessState: HomeAccessState.expired,
        ),
      ];
      await h.state.fetchHomes(autoSelect: false);
      await settle();

      expect(h.state.capabilities.isGuestExpired, isTrue);
      expect(h.state.capabilities.canControlDevices, isFalse);
      expect(h.state.cloudEndpoints, isEmpty);
      expect(h.state.expiredHomes.map((e) => e.id), <String>[kHomeA]);
      h.dispose();
    });
  });

  group('oturum olayları (tek merkez)', () {
    test('onSessionExpired: SessionExpiredEvent + yerel temizlik; ikinci çağrı yeni olay üretmez', () async {
      final h = await readyHarness();
      final events = <SessionEvent>[];
      final sub = h.state.sessionEvents.listen(events.add);

      h.cloud.onSessionExpired!(SessionEndReason.refreshRejected);
      h.cloud.onSessionExpired!(SessionEndReason.refreshRejected);
      await settle();

      expect(events, hasLength(1));
      final event = events.single as SessionExpiredEvent;
      expect(event.reason, SessionEndReason.refreshRejected);
      expect(h.state.authStatus, AuthStatus.unauthenticated);
      expect(h.state.sessionNotice, isNotNull);
      expect(h.state.currentUser, isNull);
      expect(h.state.homes, isEmpty);
      expect(h.state.cloudEndpoints, isEmpty);
      expect(h.storage.isEmpty, isTrue);
      expect(h.mqtt.isConnected, isFalse);
      await sub.cancel();
      h.dispose();
    });

    test('sessionNotice çıkış yapıldığında / yeni girişte temizlenir', () async {
      final h = await readyHarness();
      h.cloud.onSessionExpired!(SessionEndReason.invalidToken);
      await settle();
      expect(h.state.sessionNotice, isNotNull);

      h.state.clearSessionNotice();
      expect(h.state.sessionNotice, isNull);
      h.dispose();
    });

    test('onGuestExpired: GuestExpiredEvent, canlı bağlantı + yerel veri kapanır, ev listesi tazelenir', () async {
      final now = h0Now();
      final h = await readyHarness(
        home: HomeModel(
          id: kHomeA,
          name: 'Misafir Evi',
          role: 'guest',
          mqttTopicId: 'h_test',
          guestValidFrom: now.subtract(const Duration(hours: 1)),
          guestValidUntil: now.add(const Duration(hours: 5)),
        ),
      );
      final events = <SessionEvent>[];
      final sub = h.state.sessionEvents.listen(events.add);
      expect(h.state.cloudEndpoints, isNotEmpty);
      final stops = h.mqtt.stopCount;
      final fetches = h.cloud.count('fetchHomes');
      // 403 GUEST_EXPIRED: sunucu artık bu erişimi kapalı bildirir (yenilenen liste de bunu yansıtır).
      h.cloud.homes = <HomeModel>[
        HomeModel(
          id: kHomeA,
          name: 'Misafir Evi',
          role: 'guest',
          mqttTopicId: '',
          guestValidFrom: now.subtract(const Duration(hours: 1)),
          guestValidUntil: now.subtract(const Duration(minutes: 1)),
          accessState: HomeAccessState.expired,
          serverMarkedExpired: true,
        ),
      ];

      h.cloud.onGuestExpired!(kHomeA);
      await settle();

      expect(events.single, isA<GuestExpiredEvent>().having((e) => e.homeId, 'homeId', kHomeA));
      expect((events.single as GuestExpiredEvent).homeName, 'Misafir Evi');
      expect(h.state.capabilities.isGuestExpired, isTrue);
      expect(h.state.capabilities.canControlDevices, isFalse);
      expect(h.state.cloudEndpoints, isEmpty);
      expect(h.mqtt.stopCount, greaterThan(stops));
      expect(h.cloud.count('fetchHomes'), greaterThan(fetches), reason: 'sunucudaki gerçek durum alınmalı');
      expect(h.state.isAuthenticated, isTrue, reason: 'misafir süresi oturumu kapatmaz');
      await sub.cancel();
      h.dispose();
    });

    test('misafir süresi saat ilerleyince kendiliğinden dolar (zamanlayıcı)', () async {
      final now = h0Now();
      final h = await readyHarness(
        home: HomeModel(
          id: kHomeA,
          name: 'Misafir Evi',
          role: 'guest',
          mqttTopicId: 'h_test',
          guestValidFrom: now.subtract(const Duration(minutes: 5)),
          guestValidUntil: now.add(const Duration(hours: 1)),
        ),
      );
      final events = <SessionEvent>[];
      final sub = h.state.sessionEvents.listen(events.add);
      expect(h.state.capabilities.isGuest, isTrue);

      await h.clock.elapse(const Duration(hours: 1, seconds: 2));
      await settle();

      expect(events.whereType<GuestExpiredEvent>(), hasLength(1));
      expect(h.state.capabilities.isGuestExpired, isTrue);
      expect(h.state.cloudEndpoints, isEmpty);
      await sub.cancel();
      h.dispose();
    });

    test('onForbidden: rol değişmiş olabilir -> ev listesi yenilenir (30 sn içinde en fazla bir kez)', () async {
      final h = await readyHarness();
      final fetches = h.cloud.count('fetchHomes');

      h.cloud.onForbidden!(kHomeA);
      h.cloud.onForbidden!(kHomeA);
      await settle();
      expect(h.cloud.count('fetchHomes'), fetches + 1);

      await h.clock.elapse(const Duration(seconds: 31));
      h.cloud.onForbidden!(kHomeA);
      await settle();
      expect(h.cloud.count('fetchHomes'), fetches + 2);
      h.dispose();
    });

    test('depolama yazım hatası sessizce yutulmaz: storageError yüzeye çıkar', () async {
      final h = loggedOutHarness();
      h.storage.memory.failWrites = true;
      await h.state.login('a@b.c', 'parola-1234');
      await settle();
      expect(h.state.storageError, isNotNull);
      expect(h.state.isAuthenticated, isTrue, reason: 'oturum bellekte açık; kullanıcı uyarılır');

      h.state.clearStorageError();
      expect(h.state.storageError, isNull);
      h.dispose();
    });
  });

  group('servis PIN oturumu', () {
    ServiceSessionInfo session(StateHarness h, {Duration ttl = const Duration(hours: 2)}) => ServiceSessionInfo(
          homeId: kHomeB,
          homeName: 'Servis Evi',
          expiresAt: h.clock.now().add(ttl),
          technicianName: 'Usta',
        );

    test('loginWithServicePin: tek eve kapsamlı oturum; önceki kullanıcı verisi silinir; refresh yok', () async {
      final h = await readyHarness();
      h.cloud.setRefreshToken('onceki-refresh');
      h.cloud.homes = <HomeModel>[testHome(id: kHomeB, name: 'Servis Evi', role: 'service_session', topic: 'h_b')];
      h.cloud.endpoints[kHomeB] = testEndpoints(homeId: kHomeB);
      h.cloud.serviceSessionToReturn = session(h);

      final ok = await h.state.loginWithServicePin('123456', technicianName: 'Usta');
      await settle();

      expect(ok, isTrue);
      expect(h.state.isServiceSession, isTrue);
      expect(h.state.isAuthenticated, isTrue);
      expect(h.state.homes.map((e) => e.id), <String>[kHomeB]);
      expect(h.state.activeHome?.id, kHomeB);
      expect(h.state.cloudEndpoints.every((e) => e.homeId == kHomeB), isTrue);
      expect(h.state.currentUser?.role, 'service_session');
      expect(h.state.currentUser?.id, isEmpty, reason: 'servis oturumunda kullanıcı satırı yoktur');
      expect(h.state.capabilities.canCommission, isTrue);
      expect(h.state.capabilities.canManageRules, isFalse);
      expect(h.state.capabilities.canClaimDevice, isFalse);
      expect(h.state.serviceSessionRemaining, isNotNull);
      expect(await h.storage.getServiceSession(), isNotNull);
      expect(await h.storage.getRefreshToken(), isNull);
      expect(h.cloud.revokedRefreshTokens, contains('onceki-refresh'));
      h.dispose();
    });

    test('2 saat dolunca oturum kendiliğinden kapanır (SessionExpiredEvent.serviceSessionExpired)', () async {
      final h = await readyHarness();
      h.cloud.homes = <HomeModel>[testHome(id: kHomeB, name: 'Servis Evi', role: 'service_session', topic: 'h_b')];
      h.cloud.endpoints[kHomeB] = testEndpoints(homeId: kHomeB);
      h.cloud.serviceSessionToReturn = session(h);
      await h.state.loginWithServicePin('123456', technicianName: 'Usta');
      await settle();
      final events = <SessionEvent>[];
      final sub = h.state.sessionEvents.listen(events.add);

      await h.clock.elapse(const Duration(hours: 1, minutes: 59));
      expect(h.state.isServiceSession, isTrue);
      expect(h.state.serviceSessionRemaining!.inMinutes, lessThanOrEqualTo(1));

      await h.clock.elapse(const Duration(minutes: 2));
      await settle();

      expect(events.whereType<SessionExpiredEvent>(), hasLength(1));
      expect((events.single as SessionExpiredEvent).reason, SessionEndReason.serviceSessionExpired);
      expect(h.state.authStatus, AuthStatus.unauthenticated);
      expect(h.state.sessionNotice, contains('Servis'));
      expect(h.state.activeHome, isNull);
      expect(h.state.cloudEndpoints, isEmpty);
      expect(h.cloud.hasSession, isFalse, reason: 'süresi dolmuş belirteçle istek gitmemeli');
      expect(h.storage.isEmpty, isTrue);
      await sub.cancel();
      h.dispose();
    });

    test('hatalı PIN: ApiException; oturum ve yerel durum değişmez', () async {
      final h = await readyHarness();
      h.cloud.serviceLoginError = const ApiException(
        statusCode: 401,
        code: 'INVALID_CREDENTIALS',
        message: 'Geçersiz, kullanılmış veya süresi dolmuş servis PIN kodu.',
      );
      await expectLater(
        h.state.loginWithServicePin('000000'),
        throwsA(isA<ApiException>().having((e) => e.isInvalidCredentials, 'invalid', isTrue)),
      );
      expect(h.state.isServiceSession, isFalse);
      expect(h.state.currentUser?.id, 'user-1');
      expect(h.state.activeHome?.id, kHomeA);
      h.dispose();
    });

    test('ev sahibi servis PIN geçmişi / oturumları / erişimi kapatma: yalnızca owner; PIN ekrandan silinir', () async {
      final h = await readyHarness(role: 'owner');
      await h.state.generateServicePin();
      expect(h.state.servicePin, '123456');
      h.cloud.serviceTokens = <ServiceTokenSummary>[
        const ServiceTokenSummary(id: 't1', status: 'active'),
        const ServiceTokenSummary(id: 't2', status: 'used'),
      ];
      h.cloud.serviceSessions = <ServiceSessionSummary>[
        const ServiceSessionSummary(id: 's1', technicianName: 'Usta'),
      ];
      h.cloud.revokeResult = const RevokeServiceAccessResult(revokedPins: 1, revokedSessions: 1);

      expect((await h.state.fetchServiceTokens()).map((t) => t.status), <String>['active', 'used']);
      expect((await h.state.fetchServiceSessions()).single.technicianName, 'Usta');
      expect(h.cloud.count('listServiceTokens'), 1);

      final revoked = await h.state.revokeServiceAccess();
      expect(revoked.revokedPins, 1);
      expect(revoked.revokedSessions, 1);
      expect(h.state.servicePin, isNull, reason: 'iptal edilen PIN ekranda kalmamalı');
      expect(h.state.servicePinExpiry, isNull);
      expect(h.clock.activeTimerCount, lessThanOrEqualTo(1), reason: 'PIN zamanlayıcısı iptal edilmeli');

      // Yetkisiz roller
      for (final role in <String>['resident', 'guest']) {
        final other = await readyHarness(
          role: role,
          home: role == 'guest'
              ? HomeModel(
                  id: kHomeA,
                  name: 'Ev A',
                  role: 'guest',
                  mqttTopicId: 'h_test',
                  guestValidUntil: h0Now().add(const Duration(hours: 5)),
                )
              : null,
        );
        await expectLater(other.state.fetchServiceTokens(),
            throwsA(isA<ApiException>().having((e) => e.isForbidden, 'forbidden', isTrue)));
        await expectLater(other.state.revokeServiceAccess(),
            throwsA(isA<ApiException>().having((e) => e.isForbidden, 'forbidden', isTrue)));
        other.dispose();
      }
      h.dispose();
    });
  });

  group('biyometrik kilit', () {
    FakeStorage storedSession({bool biometric = true}) {
      final storage = FakeStorage();
      storage.memory.data
        ..['ahbu_auth_token'] = 'stored-access'
        ..['ahbu_refresh_token'] = 'stored-refresh'
        ..['ahbu_current_user'] = jsonEncode(user('user-1').toJson())
        ..['ahbu_biometric_enabled'] = biometric ? 'true' : 'false';
      return storage;
    }

    StateHarness initHarness({
      required FakeStorage storage,
      FakeBiometric? biometric,
      bool biometricSupported = true,
    }) {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final cloud = FakeCloudApi()
        ..homes = <HomeModel>[testHome()]
        ..endpoints[kHomeA] = testEndpoints();
      return StateHarness(
        autoInit: true,
        biometricSupported: biometricSupported,
        storage: storage,
        cloud: cloud,
        biometric: biometric,
      );
    }

    test('kilitliyken ağ ve MQTT BAŞLAMAZ; doğrulama sonrası oturum başlar', () async {
      final biometric = FakeBiometric(supported: true)..pending = Completer<bool>();
      final h = initHarness(storage: storedSession(), biometric: biometric);
      await settle();

      expect(h.state.authStatus, AuthStatus.checking);
      expect(h.state.biometricChecking, isTrue);
      expect(h.cloud.calls, isEmpty, reason: 'doğrulama bitmeden hiçbir ağ çağrısı yapılmamalı');
      expect(h.mqtt.startCount, 0);

      biometric.pending!.complete(true);
      await h.state.ready;
      await settle();

      expect(h.state.authStatus, AuthStatus.authenticated);
      expect(h.cloud.count('fetchHomes'), 1);
      expect(h.state.activeHome?.id, kHomeA);
      h.dispose();
    });

    test('doğrulama başarısız: ağ/MQTT yok, biometricFailed; yeniden denemede başarı oturumu başlatır', () async {
      final biometric = FakeBiometric(supported: true, authResult: false);
      final h = initHarness(storage: storedSession(), biometric: biometric);
      await h.state.ready;
      await settle();

      expect(h.state.authStatus, AuthStatus.checking);
      expect(h.state.biometricFailed, isTrue);
      expect(h.cloud.calls, isEmpty);
      expect(h.mqtt.startCount, 0);

      biometric.authResult = true;
      expect(await h.state.retryBiometricAuth(), isTrue);
      await settle();
      expect(h.state.authStatus, AuthStatus.authenticated);
      expect(h.cloud.count('fetchHomes'), 1);
      h.dispose();
    });

    test('şifre ile girişe düşme: belirteçler silinir, MQTT durur, refresh sunucuda iptal edilir', () async {
      final biometric = FakeBiometric(supported: true, authResult: false);
      final storage = storedSession();
      final h = initHarness(storage: storage, biometric: biometric);
      await h.state.ready;
      await settle();
      expect(h.state.biometricFailed, isTrue);

      await h.state.fallbackToPasswordLogin();
      await settle();

      expect(h.state.authStatus, AuthStatus.unauthenticated);
      expect(storage.isEmpty, isTrue);
      expect(h.mqtt.startCount, 0);
      expect(h.cloud.revokedRefreshTokens, <String>['stored-refresh']);
      h.dispose();
    });

    test('biyometrik açma ve kapama doğrulama ister; doğrulanamazsa tercih değişmez', () async {
      final h = await readyHarness();
      h.state.setBiometricForTesting(isSupported: true, isEnabled: false);
      h.biometric
        ..supported = true
        ..authResult = false;

      expect(await h.state.toggleBiometric(true), isFalse);
      expect(h.state.isBiometricEnabled, isFalse);

      h.biometric.authResult = true;
      expect(await h.state.toggleBiometric(true), isTrue);
      expect(h.state.isBiometricEnabled, isTrue);
      await settle();
      expect(await h.storage.isBiometricEnabled(), isTrue);

      // Kapatmak da doğrulama ister.
      h.biometric.authResult = false;
      final callsBefore = h.biometric.authenticateCalls;
      expect(await h.state.toggleBiometric(false), isFalse);
      expect(h.biometric.authenticateCalls, callsBefore + 1);
      expect(h.state.isBiometricEnabled, isTrue);

      h.biometric.authResult = true;
      expect(await h.state.toggleBiometric(false), isTrue);
      expect(h.state.isBiometricEnabled, isFalse);
      h.dispose();
    });

    test('desteklenmeyen cihazda biyometrik açılamaz', () async {
      final h = await readyHarness();
      h.state.setBiometricForTesting(isSupported: false);
      expect(await h.state.toggleBiometric(true), isFalse);
      expect(h.biometric.authenticateCalls, 0);
      h.dispose();
    });

    test('okunamayan biyometrik tercih: kilit AÇIK varsayılır (fail-closed)', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final storage = storedSession(biometric: false);
      final biometric = FakeBiometric(supported: true)..pending = Completer<bool>();
      // Yalnızca biyometrik tercih anahtarı okunamıyor (belirteçler okunabiliyor).
      storage.memory.failReadKeys.add('ahbu_biometric_enabled');
      final cloud = FakeCloudApi()..homes = <HomeModel>[testHome()];
      final h = StateHarness(
        autoInit: true,
        biometricSupported: true,
        storage: storage,
        cloud: cloud,
        biometric: biometric,
      );
      await settle();
      expect(h.state.authStatus, AuthStatus.checking, reason: 'tercih okunamadı -> kilitli başla');
      expect(h.state.storageError, isNotNull);
      expect(h.cloud.calls, isEmpty);
      biometric.pending!.complete(false);
      await h.state.ready;
      h.dispose();
    });
  });

  group('uygulama yaşam döngüsü', () {
    test('arka plan: MQTT durur, bekleyen komutlar iptal; ön plan: tek snapshot + MQTT yeniden başlar', () async {
      final h = await readyHarness();
      await h.state.setRelay(1, true);
      expect(h.state.commandPipeline.hasPending, isTrue);
      final fetches = h.cloud.count('fetchHomes');
      final endpoints = h.cloud.count('fetchEndpoints');
      final starts = h.mqtt.startCount;

      h.state.handleLifecycleState(AppLifecycleState.paused);
      await settle();
      expect(h.state.isInBackground, isTrue);
      expect(h.mqtt.isConnected, isFalse);
      expect(h.state.commandPipeline.hasPending, isFalse);

      // Arka planda yeni ağ çağrısı yok.
      await h.clock.elapse(const Duration(seconds: 20));
      expect(h.cloud.count('fetchHomes'), fetches);
      expect(h.cloud.count('fetchEndpoints'), endpoints);

      h.state.handleLifecycleState(AppLifecycleState.resumed);
      await settle();
      expect(h.state.isInBackground, isFalse);
      expect(h.cloud.count('fetchHomes'), fetches + 1, reason: 'roller tek kez tazelenir');
      expect(h.cloud.count('fetchEndpoints'), endpoints + 1, reason: 'tek snapshot');
      expect(h.mqtt.startCount, starts + 1);
      expect(h.mqtt.isConnected, isTrue);
      h.dispose();
    });

    test('kısa süre arka planda kalma: biyometrik yeniden kilit İSTENMEZ', () async {
      final h = await readyHarness();
      h.state.setBiometricForTesting(isSupported: true, isEnabled: true);
      h.biometric.supported = true;

      h.state.handleLifecycleState(AppLifecycleState.paused);
      await h.clock.elapse(const Duration(seconds: 10));
      h.state.handleLifecycleState(AppLifecycleState.resumed);
      await settle();

      expect(h.biometric.authenticateCalls, 0);
      expect(h.state.authStatus, AuthStatus.authenticated);
      h.dispose();
    });

    test('uzun süre arka planda kalma: yeniden kilit; doğrulanana kadar ağ/MQTT yok', () async {
      final h = await readyHarness();
      h.state.setBiometricForTesting(isSupported: true, isEnabled: true);
      h.biometric
        ..supported = true
        ..pending = Completer<bool>();
      final fetches = h.cloud.count('fetchHomes');
      final starts = h.mqtt.startCount;

      h.state.handleLifecycleState(AppLifecycleState.paused);
      await h.clock.elapse(const Duration(seconds: 45));
      h.state.handleLifecycleState(AppLifecycleState.resumed);
      await settle();

      expect(h.state.authStatus, AuthStatus.checking);
      expect(h.biometric.authenticateCalls, 1);
      expect(h.cloud.count('fetchHomes'), fetches);
      expect(h.mqtt.startCount, starts);

      h.biometric.pending!.complete(true);
      await settle();
      expect(h.state.authStatus, AuthStatus.authenticated);
      expect(h.cloud.count('fetchHomes'), fetches + 1);
      expect(h.mqtt.startCount, starts + 1);
      h.dispose();
    });

    test('tekrarlanan paused/resumed olayları tek geçiş sayılır (çift snapshot yok)', () async {
      final h = await readyHarness();
      final fetches = h.cloud.count('fetchHomes');

      h.state.handleLifecycleState(AppLifecycleState.paused);
      h.state.handleLifecycleState(AppLifecycleState.hidden);
      h.state.handleLifecycleState(AppLifecycleState.resumed);
      h.state.handleLifecycleState(AppLifecycleState.resumed);
      await settle();

      expect(h.cloud.count('fetchHomes'), fetches + 1);
      h.dispose();
    });
  });

  group('başlangıçta oturum geri yükleme (_init)', () {
    StateHarness start({
      FakeStorage? storage,
      Map<String, Object>? prefs,
      FakeCloudApi? cloud,
    }) {
      SharedPreferences.setMockInitialValues(prefs ?? <String, Object>{});
      final fakeCloud = cloud ??
          (FakeCloudApi()
            ..homes = <HomeModel>[testHome()]
            ..endpoints[kHomeA] = testEndpoints());
      return StateHarness(autoInit: true, storage: storage ?? FakeStorage(), cloud: fakeCloud);
    }

    FakeStorage withTokens({
      String? access = 'stored-access',
      String? refresh = 'stored-refresh',
      UserModel? stored,
    }) {
      final storage = FakeStorage();
      if (access != null) storage.memory.data['ahbu_auth_token'] = access;
      if (refresh != null) storage.memory.data['ahbu_refresh_token'] = refresh;
      if (stored != null) storage.memory.data['ahbu_current_user'] = jsonEncode(stored.toJson());
      return storage;
    }

    test('belirteç yok: oturum yok, ağ çağrısı yok', () async {
      final h = start();
      await h.state.ready;
      expect(h.state.authStatus, AuthStatus.unauthenticated);
      expect(h.cloud.calls, isEmpty);
      expect(h.mqtt.startCount, 0);
      h.dispose();
    });

    test('belirteç + kayıtlı kullanıcı: oturum geri yüklenir, evler alınır, ilk ev seçilir', () async {
      final h = start(storage: withTokens(stored: user('user-1', mustChange: true)));
      await h.state.ready;
      await settle();

      expect(h.state.authStatus, AuthStatus.authenticated);
      expect(h.state.currentUser?.id, 'user-1');
      expect(h.state.mustChangePassword, isTrue, reason: 'zorunlu değişim bayrağı yeniden açılışta da korunur');
      expect(h.cloud.authToken, 'stored-access');
      expect(h.cloud.currentRefreshToken, 'stored-refresh');
      expect(h.state.activeHome?.id, kHomeA);
      expect(h.mqtt.startCount, 1);
      h.dispose();
    });

    test('eski sürümün SharedPreferences belirteç yedeği (saved_auth_token) silinir', () async {
      final h = start(prefs: <String, Object>{'saved_auth_token': 'eski-yedek'});
      await h.state.ready;
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('saved_auth_token'), isFalse);
      h.dispose();
    });

    test('depolama okuma hatası "oturum yok" ile karıştırılmaz: storageError gösterilir', () async {
      final storage = withTokens(stored: user('user-1'));
      storage.memory.failReads = true;
      final h = start(storage: storage);
      await h.state.ready;
      expect(h.state.storageError, isNotNull);
      expect(h.state.authStatus, AuthStatus.unauthenticated);
      expect(h.cloud.calls, isEmpty);
      h.dispose();
    });

    test('çevrimdışı açılış: sunucu yok ama önbellekteki evlerle oturum açık kalır', () async {
      final storage = withTokens(stored: user('user-1'));
      await storage.saveHomesCache('user-1', <HomeModel>[testHome()]);
      final cloud = FakeCloudApi()
        ..fetchHomesError = ApiException.network()
        ..endpoints[kHomeA] = testEndpoints();
      final h = start(storage: storage, cloud: cloud);
      await h.state.ready;
      await settle();

      expect(h.state.authStatus, AuthStatus.authenticated);
      expect(h.state.homesFromCache, isTrue);
      expect(h.state.homesError, isNotNull);
      expect(h.state.homes.map((e) => e.id), <String>[kHomeA]);
      h.dispose();
    });

    test('yalnızca refresh token var: önce yenilenir, sonra evler alınır', () async {
      final storage = withTokens(access: null, stored: user('user-1'));
      final cloud = FakeCloudApi()
        ..homes = <HomeModel>[testHome()]
        ..endpoints[kHomeA] = testEndpoints();
      cloud.refreshHandler = () async {
        cloud.setAuthToken('yenilenen-access');
        cloud.setRefreshToken('yenilenen-refresh');
        await cloud.onTokenRefreshed?.call('yenilenen-access', 'yenilenen-refresh');
        return true;
      };
      final h = start(storage: storage, cloud: cloud);
      await h.state.ready;
      await settle();

      expect(h.cloud.calls.indexOf('refreshSession'), lessThan(h.cloud.calls.indexOf('fetchHomes')));
      expect(h.state.authStatus, AuthStatus.authenticated);
      expect(await storage.getAuthToken(), 'yenilenen-access');
      expect(await storage.getRefreshToken(), 'yenilenen-refresh');
      h.dispose();
    });

    test('yalnızca refresh token var ve kalıcı reddedildi: oturum yok, depo temiz', () async {
      final storage = withTokens(access: null, stored: user('user-1'));
      final cloud = FakeCloudApi()..homes = <HomeModel>[testHome()];
      cloud.refreshHandler = () async {
        cloud.onSessionExpired?.call(SessionEndReason.refreshRejected);
        return false;
      };
      final h = start(storage: storage, cloud: cloud);
      final events = <SessionEvent>[];
      final sub = h.state.sessionEvents.listen(events.add);
      await h.state.ready;
      await settle();

      expect(h.state.authStatus, AuthStatus.unauthenticated);
      expect(events.whereType<SessionExpiredEvent>(), hasLength(1));
      expect(storage.isEmpty, isTrue);
      expect(h.cloud.count('fetchHomes'), 0);
      await sub.cancel();
      h.dispose();
    });

    test('kullanıcı kaydı yok, access token JWT: kullanıcı belirteçten türetilir', () async {
      String b64(Map<String, dynamic> m) => base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
      final jwt = '${b64(<String, dynamic>{'alg': 'none'})}.${b64(<String, dynamic>{'sub': 'user-9', 'role': 'user'})}.sig';
      final h = start(storage: withTokens(access: jwt, refresh: null));
      await h.state.ready;
      expect(h.state.currentUser?.id, 'user-9');
      expect(h.state.authStatus, AuthStatus.authenticated);
      h.dispose();
    });

    test('kullanıcı bilinmiyor ve belirteç çözülemiyor: bozuk kayıt temizlenir', () async {
      final storage = withTokens(access: 'opak-belirtec', refresh: 'x');
      final h = start(storage: storage);
      await h.state.ready;
      await settle();
      expect(h.state.authStatus, AuthStatus.unauthenticated);
      expect(storage.isEmpty, isTrue);
      expect(h.cloud.hasSession, isFalse);
      h.dispose();
    });

    test('geçerli servis oturumu geri yüklenir; süresi dolmuş olan silinir', () async {
      final h0 = StateHarness(); // saat kaynağı için
      final valid = FakeStorage();
      valid.memory.data
        ..['ahbu_auth_token'] = 'service-access'
        ..['ahbu_service_session'] = jsonEncode(ServiceSessionInfo(
          homeId: kHomeA,
          homeName: 'Servis Evi',
          expiresAt: h0.clock.now().add(const Duration(hours: 1)),
          technicianName: 'Usta',
        ).toJson());
      h0.dispose();

      SharedPreferences.setMockInitialValues(<String, Object>{});
      final cloud = FakeCloudApi()..endpoints[kHomeA] = testEndpoints();
      final h = StateHarness(autoInit: true, storage: valid, cloud: cloud);
      await h.state.ready;
      await settle();
      expect(h.state.isServiceSession, isTrue);
      expect(h.state.activeHome?.id, kHomeA);
      expect(h.cloud.count('fetchHomes'), 0, reason: 'servis oturumunda ev listesi sunucudan alınmaz');
      expect(h.cloud.serviceSession?.homeId, kHomeA);
      h.dispose();

      // Süresi dolmuş
      final expired = FakeStorage();
      expired.memory.data
        ..['ahbu_auth_token'] = 'service-access'
        ..['ahbu_service_session'] = jsonEncode(<String, dynamic>{
          'home_id': kHomeA,
          'home_name': 'Servis Evi',
          'expires_at': DateTime.utc(2000, 1, 1).toIso8601String(),
          'technician_name': 'Usta',
        });
      final h2 = StateHarness(autoInit: true, storage: expired, cloud: FakeCloudApi());
      await h2.state.ready;
      await settle();
      expect(h2.state.authStatus, AuthStatus.unauthenticated);
      expect(expired.isEmpty, isTrue);
      h2.dispose();
    });
  });

  group('cihaz kimliği, yerel anahtar ve huzur ayarı yetkileri', () {
    test('reissueDeviceMqttCredential: owner/servis/süper ✔ (UUID normalleştirilir); sakin/misafir ✖', () async {
      final owner = await readyHarness(role: 'owner');
      final credential = await owner.state.reissueDeviceMqttCredential(deviceUuid: ' ahbu-s3-abc123 ');
      expect(credential.username, 'd_h_test');
      expect(owner.cloud.calls, contains('reissueDeviceMqttCredential:AHBU-S3-ABC123'));
      owner.dispose();

      final staff = await readyHarness(role: 'service_user', globalRole: 'service_user');
      expect((await staff.state.reissueDeviceMqttCredential(deviceUuid: 'AHBU-S3-ABC123')).host, isNotEmpty);
      staff.dispose();

      final superUser = await readyHarness(
        globalRole: 'super_user',
        home: const HomeModel(id: kHomeA, name: 'Ev A', mqttTopicId: 'h_test'),
      );
      expect((await superUser.state.reissueDeviceMqttCredential(deviceUuid: 'AHBU-S3-ABC123')).port, 8884);
      superUser.dispose();

      for (final role in <String>['resident', 'guest']) {
        final other = await readyHarness(
          role: role,
          home: role == 'guest'
              ? HomeModel(
                  id: kHomeA,
                  name: 'Ev A',
                  role: 'guest',
                  mqttTopicId: 'h_test',
                  guestValidUntil: kTestNow.add(const Duration(hours: 5)),
                )
              : null,
        );
        await expectLater(other.state.reissueDeviceMqttCredential(deviceUuid: 'AHBU-S3-ABC123'),
            throwsA(isA<ApiException>().having((e) => e.isForbidden, 'forbidden', isTrue)), reason: role);
        expect(other.cloud.count('reissueDeviceMqttCredential'), 0, reason: role);
        other.dispose();
      }
    });

    test('reissueDeviceMqttCredential: geçersiz UUID ve aktif ev yokluğu ağa gitmeden doğrulama hatası', () async {
      final h = await readyHarness(role: 'owner');
      await expectLater(h.state.reissueDeviceMqttCredential(deviceUuid: 'rastgele-metin'),
          throwsA(isA<ApiException>().having((e) => e.isValidation, 'validation', isTrue)));
      await expectLater(h.state.reissueDeviceMqttCredential(deviceUuid: 'AHBU-INVITE:ABC123'),
          throwsA(isA<ApiException>().having((e) => e.isValidation, 'validation', isTrue)));
      expect(h.cloud.count('reissueDeviceMqttCredential'), 0);
      h.dispose();
    });

    test('yerel anahtar: owner/sakin sunucudan alır ve güvenli depoya yazar; süper kullanıcı sunucuya SORMAZ', () async {
      final owner = await readyHarness(role: 'owner');
      final key = await owner.state.localKeyFor('AHBU-S3-TEST01');
      expect(key, owner.cloud.localKeyValue);
      expect(owner.cloud.count('localKey'), 1);
      await pumpEventQueue();
      expect(await owner.storage.getLocalKey('AHBU-S3-TEST01'), owner.cloud.localKeyValue);
      // İkinci çağrı depodan: sunucuya gitmez.
      expect(await owner.state.localKeyFor('AHBU-S3-TEST01'), owner.cloud.localKeyValue);
      expect(owner.cloud.count('localKey'), 1);
      owner.dispose();

      final resident = await readyHarness(role: 'resident');
      expect(await resident.state.localKeyFor('AHBU-S3-TEST01'), isNotNull);
      resident.dispose();

      final superUser = await readyHarness(
        globalRole: 'super_user',
        home: const HomeModel(id: kHomeA, name: 'Ev A', mqttTopicId: 'h_test'),
      );
      expect(await superUser.state.localKeyFor('AHBU-S3-TEST01'), isNull, reason: 'sunucu matrisi: süper local_key alamaz');
      expect(superUser.cloud.count('localKey'), 0, reason: 'garanti 403 alacak istek yapılmaz');
      superUser.dispose();
    });

    test('yerel anahtar: servis sihirbazında aktif OLMAYAN (az önce sahiplenilen) ev için homeId verilir', () async {
      final staff = await readyHarness(role: 'service_user', globalRole: 'service_user');
      expect(staff.state.activeHome?.id, kHomeA);
      final key = await staff.state.localKeyFor('AHBU-S3-ABC123', homeId: kHomeB);
      expect(key, staff.cloud.localKeyValue);
      expect(staff.cloud.localKeyHomeIds, <String>[kHomeB], reason: 'istek claim edilen eve gitmeli, aktif eve değil');
      staff.dispose();

      // Süper kullanıcı: sunucu matrisinde local_key yok -> sunucuya sorulmaz (garanti 403 yok).
      final superUser = await readyHarness(
        globalRole: 'super_user',
        home: const HomeModel(id: kHomeA, name: 'Ev A', mqttTopicId: 'h_test'),
      );
      expect(await superUser.state.localKeyFor('AHBU-S3-ABC123', homeId: kHomeB), isNull);
      expect(superUser.cloud.localKeyHomeIds, isEmpty);
      superUser.dispose();

      // homeId verilmezse aktif ev ve yetki kapısı geçerli.
      final owner = await readyHarness(role: 'owner');
      await owner.state.localKeyFor('AHBU-S3-ABC123');
      expect(owner.cloud.localKeyHomeIds, <String>[kHomeA]);
      owner.dispose();
    });

    test('peaceSettings: sunucunun uzun anahtarları tipli okunur (arayüz yanlış anahtar okumasın)', () async {
      final h = await readyHarness(role: 'owner');
      h.cloud.peaceNotification = <String, dynamic>{
        'home_id': kHomeA,
        'peace_notification_enabled': true,
        'peace_notification_time': '23:30',
        'open_lights_count': 2,
        'open_shutters_count': 0,
        'summary_text': 'Açık lamba tespit edildi (2 adet).',
        'open_lights': <dynamic>[],
      };
      await h.state.fetchPeaceNotification();
      final settings = h.state.peaceSettings!;
      expect(settings.enabled, isTrue);
      expect(settings.time, '23:30');
      expect(settings.openLightsCount, 2);
      // Ham harita da korunur (geriye uyum).
      expect(h.state.peaceNotificationData!['peace_notification_time'], '23:30');
      h.dispose();
    });
  });

  group('üye yönetimi (UUID kimlikler, yetki kapıları)', () {
    const memberUuid = '33333333-3333-4333-8333-333333333333';

    test('fetchHomeMembers: kimlikler String; removeHomeMember UUID olarak gider', () async {
      final h = await readyHarness(role: 'owner');
      h.cloud.members = <HomeMember>[
        const HomeMember(userId: memberUuid, fullName: 'Ayşe', role: 'resident'),
      ];
      final members = await h.state.fetchHomeMembers();
      expect(members.single.userId, memberUuid);

      expect(await h.state.removeHomeMember(memberUuid), isTrue);
      expect(h.cloud.removedMembers, <String>[memberUuid]);
      h.dispose();
    });

    test('sakin ve misafir üye çıkaramaz / davet üretemez (savunmacı yetki denetimi)', () async {
      final resident = await readyHarness(role: 'resident');
      await expectLater(resident.state.removeHomeMember(memberUuid),
          throwsA(isA<ApiException>().having((e) => e.isForbidden, 'forbidden', isTrue)));
      await expectLater(resident.state.createHomeInvitation(),
          throwsA(isA<ApiException>().having((e) => e.isForbidden, 'forbidden', isTrue)));
      expect(resident.cloud.removedMembers, isEmpty);
      resident.dispose();
    });

    test('aktif ev yokken üye listesi isteği doğrulama hatasıdır', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final h = StateHarness();
      h.state
        ..setCurrentUserForTesting(user('user-1'))
        ..setAuthStatusForTesting(AuthStatus.authenticated);
      await expectLater(h.state.fetchHomeMembers(),
          throwsA(isA<ApiException>().having((e) => e.isValidation, 'validation', isTrue)));
      h.dispose();
    });
  });
}

/// Test saati ([kTestNow]) ile uyumlu "şimdi".
DateTime h0Now() => kTestNow;
