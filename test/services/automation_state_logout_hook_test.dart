import 'dart:async';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/support.dart';

/// `AutomationState.addBeforeLogoutHook`: `logout()` başında (oturum belirteci hâlâ geçerliyken) EŞZAMANLI
/// başlatılan, çıkışı en çok 1 sn geciktiren ve ENGELLEMEYEN kancalar (push belirtecini silmek için).
/// Kancalar yalnızca `logout()`'ta çalışır; `logoutAll()` kendisi çalıştırmaz.
void main() {
  group('uyelik-12: servis (PIN) oturumundan çıkış', () {
    test('servis oturumunda logout sunucuya servis JWT\'siyle bildirilir; ağ hatasında da yerel çıkış olur', () async {
      for (final failing in <bool>[false, true]) {
        final h = await readyHarness();
        h.cloud.homes = <HomeModel>[testHome(id: kHomeB, name: 'Servis Evi', role: 'service_session', topic: 'h_b')];
        h.cloud.endpoints[kHomeB] = testEndpoints(homeId: kHomeB);
        if (failing) h.cloud.serviceRevokeError = ApiException.network();
        await h.state.loginWithServicePin('123456');
        await pumpEventQueue();
        expect(h.state.isServiceSession, isTrue);

        await h.state.logout();
        await pumpEventQueue();
        expect(h.cloud.revokedServiceTokens, <String>['service-access'], reason: 'hata=$failing');
        expect(h.state.isAuthenticated, isFalse);
        expect(h.state.isServiceSession, isFalse);
        h.dispose();
      }
    });

    test('normal oturumda servis çıkışı yapılmaz; refresh_token iptali aynen', () async {
      final h = await readyHarness();
      addTearDown(h.dispose);
      h.cloud.setRefreshToken('refresh-normal');
      await h.state.logout();
      await pumpEventQueue();
      expect(h.cloud.revokedServiceTokens, isEmpty);
      expect(h.cloud.revokedRefreshTokens, contains('refresh-normal'));
    });
  });

  /// Giriş yapılmamış, ev verisi hazır bir donanım (automation_state_session_test.dart ile aynı desen).
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

  Future<StateHarness> signedIn() async {
    final h = loggedOutHarness();
    await h.state.login('a@b.c', 'parola-1234');
    await pumpEventQueue();
    expect(h.state.isAuthenticated, isTrue);
    return h;
  }

  group('logout()', () {
    test('kanca oturum belirteci HÂLÂ geçerliyken çalışır; çıkış sonra tamamlanır', () async {
      final h = await signedIn();
      String? tokenInHook;
      bool? authenticatedInHook;
      var storageEmptyInHook = true;
      h.state.addBeforeLogoutHook(() async {
        tokenInHook = h.cloud.authToken;
        authenticatedInHook = h.state.isAuthenticated;
        storageEmptyInHook = h.storage.isEmpty;
      });

      await h.state.logout();

      expect(tokenInHook, 'access-1', reason: 'DELETE /me/push-tokens bu belirteçle gidebilmeli');
      expect(authenticatedInHook, isTrue);
      expect(storageEmptyInHook, isFalse, reason: 'yerel depo kanca çalışırken henüz temizlenmemiş');
      expect(h.state.isAuthenticated, isFalse);
      expect(h.cloud.authToken, isNull);
      expect(h.storage.isEmpty, isTrue);
      h.dispose();
    });

    test('kanca sunucu çağrısı yapabilir (belirteç geçerli): refresh iptalinden ÖNCE gider', () async {
      final h = await signedIn();
      h.state.addBeforeLogoutHook(() async {
        h.cloud.calls.add('hook');
      });
      await h.state.logout();
      await pumpEventQueue();
      final calls = h.cloud.calls;
      expect(calls.indexOf('hook'), greaterThanOrEqualTo(0));
      expect(calls.indexOf('hook'), lessThan(calls.indexOf('revokeRefreshToken')));
      h.dispose();
    });

    test('hata (eşzamanlı ve eşzamansız) yutulur; çıkış yine tamamlanır', () async {
      final h = await signedIn();
      var survivorRan = false;
      h.state.addBeforeLogoutHook(() => throw StateError('eşzamanlı hata'));
      h.state.addBeforeLogoutHook(() async => throw StateError('eşzamansız hata'));
      h.state.addBeforeLogoutHook(() async => survivorRan = true);

      await h.state.logout();

      expect(survivorRan, isTrue, reason: 'bir kancanın hatası diğerlerini engellemez');
      expect(h.state.isAuthenticated, isFalse);
      expect(h.storage.isEmpty, isTrue);
      h.dispose();
    });

    test('kancalar paralel çalışır (her biri çıkıştan önce başlar)', () async {
      final h = await signedIn();
      final gateA = Completer<void>();
      final gateB = Completer<void>();
      final started = <String>[];
      h.state.addBeforeLogoutHook(() async {
        started.add('a');
        await gateA.future;
      });
      h.state.addBeforeLogoutHook(() async {
        started.add('b');
        await gateB.future;
      });

      final done = h.state.logout();
      await pumpEventQueue();
      expect(started, <String>['a', 'b'], reason: 'b, a bitmeden başlar');
      expect(h.state.isAuthenticated, isTrue, reason: 'kancalar bitmeden (ve 1 sn dolmadan) yerel temizlik beklenir');

      gateA.complete();
      gateB.complete();
      await done;
      expect(h.state.isAuthenticated, isFalse);
      h.dispose();
    });

    test('kancalar logout() başında EŞZAMANLI başlar (belirteç hâlâ geçerli, hiçbir await öncesi)', () async {
      final h = await signedIn();
      String? tokenAtStart;
      var started = false;
      h.state.addBeforeLogoutHook(() async {
        started = true;
        tokenAtStart = h.cloud.authToken;
      });
      final future = h.state.logout();
      expect(started, isTrue, reason: 'istek, belirteç silinmeden önce eşzamanlı başlatılmış olmalı');
      expect(tokenAtStart, 'access-1');
      await future;
      h.dispose();
    });

    test('takılan kanca yerel temizliği en çok 1 sn geciktirir; kanca arka planda sürer (sahte saat)', () async {
      final h = await signedIn();
      Completer<void>? gate; // sahte saat bölgesinde oluşturulmalı (tamamlama mikro görevi o bölgeye gider)
      var finished = false;
      h.state.addBeforeLogoutHook(() async {
        await gate!.future;
        finished = true;
      });

      // Not: yerel depo/tercih yazımları gerçek platform asenkronu kullandığından `logout()` futuru sahte
      // saatte tamamlanmaz; zamanlama `isAuthenticated`'ın ne zaman düştüğüyle ölçülür.
      fakeAsync((async) {
        gate = Completer<void>();
        h.state.logout();
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 999));
        expect(h.state.isAuthenticated, isTrue, reason: '1 sn dolmadan yerel temizlik yok');
        async.elapse(const Duration(milliseconds: 1));
        expect(h.state.isAuthenticated, isFalse, reason: '1 sn dolunca yerel temizlik HEMEN yapılır');
        expect(h.cloud.authToken, isNull);
        async.flushMicrotasks();
        expect(finished, isFalse, reason: 'kanca hâlâ sürüyor (arka planda)');

        gate!.complete();
        async.flushMicrotasks();
        expect(finished, isTrue, reason: 'kanca arka planda tamamlanmaya devam eder');
      });
      h.dispose();
    });

    test('hızlı biten kanca çıkışı 1 sn bekletmez (sahte saat: zaman ilerlemeden tamamlanır)', () async {
      final h = await signedIn();
      h.state.addBeforeLogoutHook(() async {});
      fakeAsync((async) {
        h.state.logout();
        async.flushMicrotasks();
        expect(h.state.isAuthenticated, isFalse);
      });
      h.dispose();
    });

    test('hızlı biten kanca: 1 sn bekleme zamanlayıcısı iptal edilir (sarkan zamanlayıcı kalmaz)', () async {
      final h = await signedIn();
      h.state.addBeforeLogoutHook(() async {});
      fakeAsync((async) {
        h.state.logout();
        async.flushMicrotasks();
        expect(h.state.isAuthenticated, isFalse);
        expect(async.pendingTimers.where((t) => t.duration == const Duration(seconds: 1)), isEmpty);
        expect(async.pendingTimers.where((t) => t.duration == const Duration(seconds: 3)), isEmpty);
      });
      h.dispose();
    });

    test('hiç bitmeyen kanca: 3 sn tavanı arka planda sessizce dolar (hata sızmaz)', () async {
      final h = await signedIn();
      h.state.addBeforeLogoutHook(() => Completer<void>().future); // asla bitmez
      fakeAsync((async) {
        h.state.logout();
        async.elapse(const Duration(seconds: 1));
        expect(h.state.isAuthenticated, isFalse);
        async.elapse(const Duration(seconds: 3)); // kanca başına 3 sn tavan
        async.flushMicrotasks();
        expect(async.pendingTimers.where((t) => t.duration == const Duration(seconds: 3)), isEmpty);
      });
      h.dispose();
    });

    test('yavaş kanca gerçek zamanda da çıkışı ~1 sn içinde tamamlar', () async {
      final h = await signedIn();
      h.state.addBeforeLogoutHook(() => Completer<void>().future); // asla bitmez
      final watch = Stopwatch()..start();
      await h.state.logout();
      watch.stop();
      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(950));
      expect(watch.elapsedMilliseconds, lessThan(2500));
      expect(h.state.isAuthenticated, isFalse);
      expect(h.storage.isEmpty, isTrue);
      h.dispose();
    });

    test('eşzamanlı ikinci logout(): kancalar İKİNCİ kez çalışmaz (tek uçuş)', () async {
      final h = await signedIn();
      final gate = Completer<void>();
      var runs = 0;
      h.state.addBeforeLogoutHook(() async {
        runs++;
        await gate.future;
      });
      final first = h.state.logout();
      final second = h.state.logout();
      await pumpEventQueue();
      expect(runs, 1);
      gate.complete();
      await Future.wait(<Future<void>>[first, second]);
      expect(runs, 1);
      expect(h.state.isAuthenticated, isFalse);
      h.dispose();
    });

    test('yeni oturumun çıkışında kancalar yeniden çalışır (önceki oturumun uçuşu yeniden kullanılmaz)', () async {
      final h = await signedIn();
      var runs = 0;
      h.state.addBeforeLogoutHook(() async => runs++);
      await h.state.logout();
      await h.state.login('a@b.c', 'parola-1234');
      await pumpEventQueue();
      await h.state.logout();
      expect(runs, 2);
      h.dispose();
    });

    test('önceki çıkışın kancası arka planda asılıyken bile yeni oturum çıkışında kanca yeniden çalışır', () async {
      final h = await signedIn();
      var runs = 0;
      h.state.addBeforeLogoutHook(() {
        runs++;
        return Completer<void>().future; // asla bitmez
      });
      await h.state.logout(); // ~1 sn
      await h.state.login('a@b.c', 'parola-1234');
      await pumpEventQueue();
      await h.state.logout();
      expect(runs, 2);
      h.dispose();
    });

    test('kaldırıcı geri çağrı kancayı siler', () async {
      final h = await signedIn();
      var runs = 0;
      final remove = h.state.addBeforeLogoutHook(() async => runs++);
      remove();
      remove(); // ikinci çağrı zararsız
      await h.state.logout();
      expect(runs, 0);
      h.dispose();
    });

    test('kanca yokken zamanlama değişmez: await yapılmaz, oturum ilk eşzamanlı adımda sıfırlanır', () async {
      final h = await signedIn();
      // logout() ilk `await`'ine kadar eşzamanlı çalışır: kanca yoksa durum çağrı döner dönmez sıfırdır.
      final future = h.state.logout();
      expect(h.state.isAuthenticated, isFalse, reason: 'kanca yokken çıkış ilk senkron adımda uygulanır');
      expect(h.cloud.authToken, isNull);
      await future;
      h.dispose();
    });

    test('kanca varken çıkış ilk eşzamanlı adımda UYGULANMAZ (kanca beklenir)', () async {
      final h = await signedIn();
      final gate = Completer<void>();
      h.state.addBeforeLogoutHook(() => gate.future);
      final future = h.state.logout();
      expect(h.state.isAuthenticated, isTrue);
      gate.complete();
      await future;
      expect(h.state.isAuthenticated, isFalse);
      h.dispose();
    });
  });

  group('logoutAll()', () {
    test('başarılı logoutAll: kanca TAM BİR KEZ, logout() içinde (sunucu çağrısından sonra) çalışır', () async {
      final h = await signedIn();
      var runs = 0;
      h.state.addBeforeLogoutHook(() async {
        runs++;
        h.cloud.calls.add('hook');
      });

      await h.state.logoutAll();
      await pumpEventQueue();

      final calls = h.cloud.calls;
      expect(runs, 1, reason: 'logoutAll ve logout kancayı iki kez çalıştırmamalı');
      expect(calls.indexOf('logoutAll'), greaterThanOrEqualTo(0));
      expect(calls.indexOf('logoutAll'), lessThan(calls.indexOf('hook')));
      expect(h.state.isAuthenticated, isFalse);
      h.dispose();
    });

    test('sunucu hatasında çıkış yapılmaz VE kanca ÇALIŞMAZ (kullanıcı oturumda kalır, push kapanmaz)', () async {
      final h = await signedIn();
      var runs = 0;
      h.state.addBeforeLogoutHook(() async => runs++);
      h.cloud.logoutAllError = ApiException.network();

      await expectLater(h.state.logoutAll(), throwsA(isA<ApiException>()));
      await pumpEventQueue();

      expect(h.state.isAuthenticated, isTrue);
      expect(runs, 0);
      h.dispose();
    });

    test('servis oturumu: yerel çıkış; kanca logout() içinde bir kez çalışır ve çıkış tamamlanır', () async {
      final h = await readyHarness(globalRole: 'service_session', role: 'service_session');
      var runs = 0;
      h.state.addBeforeLogoutHook(() async => runs++);
      await h.state.logoutAll();
      expect(h.cloud.count('logoutAll'), 0);
      expect(runs, 1);
      expect(h.state.isAuthenticated, isFalse);
      h.dispose();
    });
  });
}
