import 'dart:async';
import 'dart:convert';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/models/legal_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/support.dart';
import '../ui/e2_support.dart' show E2Cloud;

/// Durum katmanında yasal metinler: kayıtta onaylanan sürümün iletilmesi, sözleşme onay kapısının koşulu
/// ([AutomationState.needsTermsAcceptance]), onay -> `GET /auth/me` -> devam akışı ve geri yüklenen oturumda yasal
/// durumun sunucuyla eşitlenmesi.
void main() {
  const pendingUser = UserModel(id: 'user-1', email: 'a@b.c', fullName: 'Ayşe', legal: UserLegalStatus(
    termsCurrentVersion: 1,
    termsStatus: 'final',
    needsAcceptance: true,
  ));

  StateHarness signedIn({UserModel user = pendingUser, AppMode mode = AppMode.cloud}) {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final h = StateHarness();
    addTearDown(h.dispose);
    h.cloud.legalDocuments = testLegalDocuments(termsStatus: 'final');
    h.cloud.beginSession(accessToken: 'access-1', refreshToken: 'refresh-1');
    h.state
      ..setCurrentUserForTesting(user)
      ..setAuthStatusForTesting(AuthStatus.authenticated)
      ..setModeForTesting(mode);
    return h;
  }

  group('needsTermsAcceptance (onay kapısı koşulu)', () {
    test('bulutta oturum açmış kullanıcı ve sunucu needs_acceptance=true -> true', () {
      final h = signedIn();
      expect(h.state.needsTermsAcceptance, isTrue);
    });

    test('sunucu onay istemiyorsa (needs_acceptance=false / legal yok) -> false', () {
      expect(signedIn(user: pendingUser.copyWith(legal: UserLegalStatus.none)).state.needsTermsAcceptance, isFalse);
      expect(
        signedIn(user: pendingUser.copyWith(legal: const UserLegalStatus(termsCurrentVersion: 1, termsStatus: 'draft')))
            .state
            .needsTermsAcceptance,
        isFalse,
        reason: 'taslak metin onay istemez (sunucu false döner)',
      );
    });

    test('yerel ağ (LAN) kipinde HİÇBİR ZAMAN -> false', () {
      expect(signedIn(mode: AppMode.direct).state.needsTermsAcceptance, isFalse);
    });

    test('personel (süper / servis sorumlusu) için HİÇBİR ZAMAN -> false (sunucu da false döner)', () {
      expect(signedIn(user: pendingUser.copyWith(role: 'super_user')).state.needsTermsAcceptance, isFalse);
      expect(signedIn(user: pendingUser.copyWith(role: 'service_user')).state.needsTermsAcceptance, isFalse);
    });

    test('servis PIN oturumunda HİÇBİR ZAMAN -> false', () {
      final h = signedIn(user: pendingUser.copyWith(role: 'service_session'));
      expect(h.state.needsTermsAcceptance, isFalse);

      final h2 = signedIn();
      h2.cloud.restoreServiceSession(
        accessToken: 'service-access',
        info: ServiceSessionInfo(homeId: kHomeA, homeName: 'Ev', expiresAt: h2.clock.now().add(const Duration(hours: 2)), technicianName: ''),
      );
      expect(h2.state.needsTermsAcceptance, isFalse);
    });

    test('oturum yoksa -> false', () {
      final h = signedIn();
      h.state.setAuthStatusForTesting(AuthStatus.unauthenticated);
      expect(h.state.needsTermsAcceptance, isFalse);
    });
  });

  group('acceptTerms: POST /legal/accept -> GET /auth/me -> devam', () {
    test('onay gönderilir, kullanıcı /auth/me ile yenilenir ve saklanır; kapı kalkar', () async {
      final h = signedIn();
      h.cloud.meUser = pendingUser.copyWith(legal: const UserLegalStatus(
        termsAcceptedVersion: 1,
        termsCurrentVersion: 1,
        termsStatus: 'final',
      ));

      await h.state.acceptTerms(1);

      expect(h.cloud.legalLog, <String>['legal:accept:terms:1', 'me'], reason: 'önce onay, sonra kullanıcı yenilenir');
      expect(h.state.needsTermsAcceptance, isFalse);
      expect(h.state.currentUser!.legal.termsAcceptedVersion, 1);
      await pumpEventQueue();
      final stored = UserModel.fromJson(jsonDecode(h.storage.memory.data['ahbu_current_user']!) as Map<String, dynamic>);
      expect(stored.legal.needsAcceptance, isFalse, reason: 'yeniden açılışta kapı yine çıkmaz');
    });

    test('/auth/me alınamazsa (ağ) onay yine geçerlidir: yerel durum güncellenir, ÇIKMAZ yok', () async {
      final h = signedIn();
      h.cloud.meError = ApiException.network();

      await h.state.acceptTerms(1);

      expect(h.cloud.legalAccepts.single, (document: 'terms', version: 1));
      expect(h.state.needsTermsAcceptance, isFalse);
      expect(h.state.currentUser!.legal.termsAcceptedVersion, 1);
    });

    test('409 LEGAL_VERSION_MISMATCH iletilir; kullanıcı onaylamamış sayılır ve /auth/me çağrılmaz', () async {
      final h = signedIn();
      h.cloud.legalDocuments = testLegalDocuments(termsVersion: 2, termsStatus: 'final');

      await expectLater(
        h.state.acceptTerms(1),
        throwsA(isA<ApiException>().having((e) => e.isLegalVersionMismatch, 'isLegalVersionMismatch', isTrue)),
      );
      expect(h.state.needsTermsAcceptance, isTrue);
      expect(h.cloud.meCalls, 0);
    });

    test('ağ hatasında hata iletilir ve kapı sürer (yeniden denenebilir)', () async {
      final h = signedIn();
      h.cloud.legalAcceptError = ApiException.network();

      await expectLater(h.state.acceptTerms(1), throwsA(isA<ApiException>().having((e) => e.isNetwork, 'isNetwork', isTrue)));
      expect(h.state.needsTermsAcceptance, isTrue);

      h.cloud.legalAcceptError = null;
      await h.state.acceptTerms(1);
      expect(h.state.needsTermsAcceptance, isFalse);
    });

    test('/auth/me hâlâ onay istiyorsa (bu arada yeni sürüm yayımlandı) kapı sürer', () async {
      final h = signedIn();
      h.cloud.meUser = pendingUser.copyWith(legal: pendingTerms(current: 2, accepted: 1));

      await h.state.acceptTerms(1);

      expect(h.state.needsTermsAcceptance, isTrue);
      expect(h.state.currentUser!.legal.termsCurrentVersion, 2);
    });

    test('servis PIN oturumunda yasak (403); istek gitmez', () async {
      final h = signedIn(user: pendingUser.copyWith(role: 'service_session'));
      await expectLater(h.state.acceptTerms(1), throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 403)));
      expect(h.cloud.legalAccepts, isEmpty);
    });
  });

  group('refreshCurrentUser (GET /auth/me)', () {
    test('aynı kullanıcıysa güncellenir; başka hesabın yanıtı uygulanmaz', () async {
      final h = signedIn(user: pendingUser.copyWith(legal: UserLegalStatus.none));
      h.cloud.meUser = pendingUser.copyWith(fullName: 'Ayşe Yılmaz');

      expect(await h.state.refreshCurrentUser(), isTrue);
      expect(h.state.currentUser!.fullName, 'Ayşe Yılmaz');
      expect(h.state.needsTermsAcceptance, isTrue);

      h.cloud.meUser = const UserModel(id: 'baska', email: 'x@y.z', fullName: 'Başkası');
      expect(await h.state.refreshCurrentUser(), isFalse);
      expect(h.state.currentUser!.id, 'user-1');
    });
  });

  group('register: kayıt ekranında onaylanan sürüm iletilir', () {
    test('acceptTermsVersion sunucu istemcisine aynen geçer', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final cloud = E2Cloud();
      final h = StateHarness(cloud: cloud);
      addTearDown(h.dispose);
      h.state.setAuthStatusForTesting(AuthStatus.unauthenticated);

      await h.state.register(fullName: 'Ayşe', email: 'a@b.c', password: 'parola-123456', acceptTermsVersion: 3);

      expect(cloud.registerArgs.single['acceptTermsVersion'], 3);
      expect(h.state.authStatus, AuthStatus.authenticated);
    });
  });

  group('geri yüklenen oturumda yasal durum sunucuyla eşitlenir', () {
    Future<StateHarness> restore({
      UserModel? stored,
      required void Function(FakeCloudApi cloud) configure,
      Map<String, Object> prefs = const <String, Object>{},
    }) async {
      SharedPreferences.setMockInitialValues(<String, Object>{...prefs});
      final storage = FakeStorage();
      storage.memory.data
        ..['ahbu_auth_token'] = 'stored-access'
        ..['ahbu_refresh_token'] = 'stored-refresh'
        ..['ahbu_current_user'] = jsonEncode((stored ?? const UserModel(id: 'user-1', email: 'a@b.c', fullName: 'Ayşe')).toJson());
      final cloud = FakeCloudApi()
        ..homes = <HomeModel>[testHome()]
        ..endpoints[kHomeA] = testEndpoints()
        ..devicesByHome[kHomeA] = <DeviceInfo>[
          const DeviceInfo(deviceUuid: 'AHBU-S3-TEST01', name: 'Pano', online: true, firmware: '1.1.0'),
        ];
      configure(cloud);
      final h = StateHarness(autoInit: true, storage: storage, cloud: cloud);
      addTearDown(h.dispose);
      await h.clock.elapse(const Duration(seconds: 1));
      return h;
    }

    test('saklı kayıtta onay yok ama sözleşme bu arada kesinleşti: kapı açılışta çıkar ve kayıt güncellenir', () async {
      final h = await restore(
        configure: (cloud) => cloud.meUser = const UserModel(id: 'user-1', email: 'a@b.c', fullName: 'Ayşe', legal: UserLegalStatus(
          termsCurrentVersion: 1,
          termsStatus: 'final',
          needsAcceptance: true,
        )),
      );

      expect(h.state.authStatus, AuthStatus.authenticated);
      expect(h.cloud.meCalls, 1);
      expect(h.state.needsTermsAcceptance, isTrue);
      await pumpEventQueue();
      final stored = UserModel.fromJson(jsonDecode(h.storage.memory.data['ahbu_current_user']!) as Map<String, dynamic>);
      expect(stored.legal.needsAcceptance, isTrue);
    });

    const finalTermsPending = UserModel(id: 'user-1', email: 'a@b.c', fullName: 'Ayşe', legal: UserLegalStatus(
      termsCurrentVersion: 2,
      termsStatus: 'final',
      needsAcceptance: true,
    ));

    test('cekirdek-6: yerel ağ (LAN) kipinde açılan oturum buluta geçince yasal durum eşitlenir', () async {
      final h = await restore(
        prefs: const <String, Object>{'saved_app_mode': 'direct'},
        configure: (cloud) => cloud.meUser = finalTermsPending,
      );
      expect(h.state.mode, AppMode.direct);
      expect(h.cloud.meCalls, 0, reason: 'LAN kipinde eşitleme yok');
      expect(h.state.needsTermsAcceptance, isFalse);

      await h.state.setMode(AppMode.cloud);
      await pumpEventQueue();

      expect(h.cloud.meCalls, 1);
      expect(h.state.needsTermsAcceptance, isTrue, reason: 'v2 sözleşme buluta geçişte sorulur');
    });

    test('cekirdek-6: ön plana dönüşte son eşitlemeden 12 sa geçtiyse bir kez eşitlenir; daha kısa sürede eşitlenmez', () async {
      final h = await restore(configure: (cloud) => cloud.meUser = const UserModel(id: 'user-1', email: 'a@b.c', fullName: 'Ayşe'));
      expect(h.cloud.meCalls, 1, reason: 'açılış eşitlemesi');
      h.cloud.meUser = finalTermsPending;

      Future<void> backgroundFor(Duration away) async {
        h.state.handleLifecycleState(AppLifecycleState.paused);
        h.clock.advance(away);
        h.state.handleLifecycleState(AppLifecycleState.resumed);
        await pumpEventQueue(times: 40);
      }

      await backgroundFor(const Duration(hours: 13));
      expect(h.cloud.meCalls, 2);
      expect(h.state.needsTermsAcceptance, isTrue);

      await backgroundFor(const Duration(hours: 1));
      expect(h.cloud.meCalls, 2, reason: '12 sa dolmadı: yeni istek yok');
    });

    test('yalnız yasal durum değişir: ad / rol gibi alanlar saklı kayıttan kalır', () async {
      final h = await restore(
        configure: (cloud) => cloud.meUser = const UserModel(id: 'user-1', email: 'a@b.c', fullName: 'Sunucudaki Ad'),
      );
      expect(h.state.currentUser!.fullName, 'Ayşe');
    });

    test('açılış eşitlemesinin GEÇ gelen eski yanıtı, bu arada verilen onayı geri almaz (kapı yeniden açılmaz)', () async {
      const pending = UserModel(id: 'user-1', email: 'a@b.c', fullName: 'Ayşe', legal: UserLegalStatus(
        termsCurrentVersion: 1,
        termsStatus: 'final',
        needsAcceptance: true,
      ));
      final slow = Completer<void>();
      final h = await restore(
        stored: pending,
        configure: (cloud) => cloud
          ..legalDocuments = testLegalDocuments(termsStatus: 'final')
          ..meUser = pending // eşitleme isteği gittiğinde sunucu hâlâ onay bekliyor
          ..meGate = slow,
      );
      expect(h.cloud.meCalls, 1, reason: 'açılış eşitlemesi yolda');
      expect(h.state.needsTermsAcceptance, isTrue);

      // Yanıt gecikirken kullanıcı onaylar: POST /legal/accept -> GET /auth/me (güncel durum) -> kapı kalkar.
      h.cloud
        ..meGate = null
        ..meUser = pending.copyWith(legal: const UserLegalStatus(
          termsAcceptedVersion: 1,
          termsCurrentVersion: 1,
          termsStatus: 'final',
        ));
      await h.state.acceptTerms(1);
      expect(h.state.needsTermsAcceptance, isFalse);

      // Onaydan ÖNCEKİ durumu taşıyan eşitleme yanıtı şimdi gelir: uygulanmamalı.
      slow.complete();
      await pumpEventQueue();
      expect(h.state.needsTermsAcceptance, isFalse, reason: 'eski yanıt onayı geri almamalı');
      expect(h.state.currentUser!.legal.termsAcceptedVersion, 1);
      final stored = UserModel.fromJson(jsonDecode(h.storage.memory.data['ahbu_current_user']!) as Map<String, dynamic>);
      expect(stored.legal.needsAcceptance, isFalse, reason: 'saklı kayıt da eski yanıtla ezilmez');
    });

    test('/auth/me alınamazsa saklı durum korunur (onay bekleyen kullanıcı kapıyı atlamaz)', () async {
      final h = await restore(
        stored: const UserModel(id: 'user-1', email: 'a@b.c', fullName: 'Ayşe', legal: UserLegalStatus(
          termsCurrentVersion: 1,
          termsStatus: 'final',
          needsAcceptance: true,
        )),
        configure: (cloud) => cloud.meError = ApiException.network(),
      );
      expect(h.state.authStatus, AuthStatus.authenticated);
      expect(h.state.needsTermsAcceptance, isTrue);
    });

    test('servis PIN oturumu geri yüklenince /auth/me ÇAĞRILMAZ', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final storage = FakeStorage();
      final clock = FakeClock();
      storage.memory.data['ahbu_auth_token'] = 'service-access';
      await storage.saveServiceSession(ServiceSessionInfo(
        homeId: kHomeA,
        homeName: 'Ev A',
        expiresAt: clock.now().add(const Duration(hours: 2)),
        technicianName: 'Usta',
      ));
      final cloud = FakeCloudApi(clock: clock)
        ..endpoints[kHomeA] = testEndpoints()
        ..devicesByHome[kHomeA] = <DeviceInfo>[
          const DeviceInfo(deviceUuid: 'AHBU-S3-TEST01', name: 'Pano', online: true, firmware: '1.1.0'),
        ];
      final h = StateHarness(autoInit: true, storage: storage, cloud: cloud, clock: clock);
      addTearDown(h.dispose);
      await h.clock.elapse(const Duration(seconds: 1));

      expect(h.state.isServiceSession, isTrue);
      expect(cloud.meCalls, 0);
    });
  });
}
