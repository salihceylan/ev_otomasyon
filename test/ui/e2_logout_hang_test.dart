import 'dart:async';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/common/confirm_dialogs.dart';
import 'package:ev_otomasyon/ui/common/wifi_provision_panel.dart';
import 'package:ev_otomasyon/ui/pages/family/join_home_dialog.dart';
import 'package:ev_otomasyon/ui/pages/wifi_recovery_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/support.dart';
import 'e2_support.dart';
import 'e2_wifi_support.dart';

/// ASKIDA KALMA testleri (Dalga 5a, WP-UI-DIALOGS; ölçümsüz performans iddiası yok, kanıt = zaman aşımı
/// davranışı): takılan platform çağrısı / sunucu yanıtı arayüzü kalıcı kilitlememeli.
///
///  * PF-31: `confirmAndLogout` — depo toplu silmesi (`deleteAll`) takılırsa global `_logoutRunning`
///    bayrağı kalıcı `true` kalıyor, sonraki TÜM çıkış dokunuşları sessizce ölüydü.
///  * PF-43: `WifiProvisionPanel.onDeviceChecked` / `WifiRecoveryDialog` yerel anahtar okuması takılırsa
///    pano bağlantı testi sonsuza dek "kontrol ediliyor" kalıyordu (Wi-Fi kurtarma panonun ACİL yolu).
///  * PF-50: `JoinHomeDialog` uzun işlemde (REST + ev listesi + ev seçimi zinciri) ilerleme göstermeli ve
///    25 sn sonra "Kapat" sunmalı.
///
/// Zaman SAHTE saatle ilerletilir (`env.clock.advance`): depo/biyometrik süre sınırı (PF-02) ve bu
/// paketin sınırları aynı `Clock`'tan kurulur.
void main() {
  /// `e2Env` ile aynı kurulum; yalnızca sahte bulut (yavaş/takılı uçlar için) ve depo verilebilir.
  E2Env envWith(
    E2Cloud Function(FakeClock clock) makeCloud, {
    String? role = 'owner',
    String globalRole = 'user',
    FakeStorage? storage,
  }) {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final clock = FakeClock();
    final cloud = makeCloud(clock);
    final h = StateHarness(clock: clock, cloud: cloud, storage: storage);
    h.state
      ..setCurrentUserForTesting(
        UserModel(id: kUserId, email: kUserEmail, fullName: 'Ayşe Yılmaz', phone: kUserPhone, role: globalRole),
      )
      ..setAuthStatusForTesting(AuthStatus.authenticated);
    if (role != null) {
      final active = testHome(role: role);
      h.state.setHomesForTesting(<HomeModel>[active], activeHome: active);
    }
    addTearDown(h.dispose);
    return E2Env(h, cloud);
  }

  /// `DialogBusyNotice`'in şu an gösterdiği metin.
  String noticeText(WidgetTester tester, String key) => tester.widget<DialogBusyNotice>(find.byKey(Key(key))).text;

  // ---------------------------------------------------------------------------------------------
  // PF-31: confirmAndLogout
  // ---------------------------------------------------------------------------------------------
  group('confirmAndLogout: takılan depo çıkışı kalıcı kilitlemez (PF-31)', () {
    /// Giriş yapılmış durum + üzerinde itilmiş bir sayfa olan uygulama (`e2_confirm_dialogs_test` kalıbı).
    Future<E2Env> pumpWithPushedPage(WidgetTester tester, {FakeStorage? storage}) async {
      final env = e2Env(role: null, authenticated: false, storage: storage);
      await env.state.login(kUserEmail, kStrongPassword);
      await settle(tester, frames: 1);
      expect(env.state.authStatus, AuthStatus.authenticated);

      await pumpApp(
        tester,
        state: env.state,
        child: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                key: const Key('push_page'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (pageContext) => Scaffold(
                      appBar: AppBar(title: const Text('İkinci sayfa')),
                      body: Center(
                        child: ElevatedButton(
                          key: const Key('do_logout'),
                          onPressed: () => confirmAndLogout(pageContext, env.state),
                          child: const Text('Çık'),
                        ),
                      ),
                    ),
                  ),
                ),
                child: const Text('Aç'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('push_page')));
      await settle(tester);
      expect(find.text('İkinci sayfa'), findsOneWidget);
      return env;
    }

    Future<void> tapLogoutAndConfirm(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('do_logout')));
      await settle(tester);
      expect(find.text('Çıkış Yapılsın mı?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('btn_logout_confirm')));
      await settle(tester);
    }

    testWidgets(
      'toplu silme SONSUZA DEK takılsa bile (servis sınırı olmasa da) çıkış 10 sn içinde biter; yığın temizlenir ve '
      'ikinci çıkış dokunuşu yine onay diyaloğunu açar',
      (tester) async {
        final store = InMemorySecureStore();
        // Servis düzeyi süre sınırı (PF-02) BİLEREK devre dışı: yalnızca `confirmAndLogout` emniyeti sınanır.
        final storage = FakeStorage(memory: store, opTimeout: const Duration(days: 365));
        final env = await pumpWithPushedPage(tester, storage: storage);
        store.hangDeleteAll = Completer<void>(); // çıkıştaki toplu silme takıldı (Keystore/Keychain)
        final deletesBefore = store.deleteAllCount; // giriş akışı da toplu silme çağırmış olabilir

        await tapLogoutAndConfirm(tester);

        // Yerel oturum hemen sıfırlandı; toplu silme takılı: çıkış tamamlanmadı (sayfa hâlâ açık).
        expect(env.state.authStatus, AuthStatus.unauthenticated);
        expect(store.deleteAllCount, deletesBefore + 1, reason: 'çıkış toplu silmeyi başlattı ve takıldı');
        expect(find.text('İkinci sayfa'), findsOneWidget, reason: 'çıkış henüz bitmedi');

        // Süren çıkış sırasında ikinci dokunuş yok sayılır (çift çıkış koruması BOZULMADI).
        await tester.tap(find.byKey(const Key('do_logout')));
        await settle(tester);
        expect(find.text('Çıkış Yapılsın mı?'), findsNothing, reason: 'çıkış sürerken ikinci diyalog açılmaz');
        expect(store.deleteAllCount, deletesBefore + 1);

        // 10 sn'lik emniyet: TimeoutException yutulur, yığın yine de temizlenir.
        env.clock.advance(const Duration(seconds: 11));
        await settle(tester);
        await tester.pump(const Duration(milliseconds: 500)); // sayfa kapanış geçişi
        expect(find.text('İkinci sayfa'), findsNothing, reason: 'zaman aşımı sonrası navigator ilk rotaya döndü');
        expect(find.byKey(const Key('push_page')), findsOneWidget);
        expect(tester.takeException(), isNull);

        // Bayrak sıfırlandı: ikinci çıkış dokunuşu YİNE onay diyaloğunu açar.
        await tester.tap(find.byKey(const Key('push_page')));
        await settle(tester);
        await tester.tap(find.byKey(const Key('do_logout')));
        await settle(tester);
        expect(find.text('Çıkış Yapılsın mı?'), findsOneWidget, reason: '_logoutRunning kalıcı true kalmamalı');
        await tester.tap(find.byKey(const Key('btn_logout_cancel')));
        await settle(tester);
      },
    );

    testWidgets(
      'depo takılı + varsayılan servis sınırı (6 sn): çıkış tamamlanır, depo hatası yüzeye çıkar ve ikinci çıkış açılır',
      (tester) async {
        final store = InMemorySecureStore();
        final env = await pumpWithPushedPage(tester, storage: FakeStorage(memory: store));
        store.hangDeleteAll = Completer<void>();

        await tapLogoutAndConfirm(tester);
        expect(find.text('İkinci sayfa'), findsOneWidget, reason: 'servis sınırı dolana kadar çıkış sürer');

        env.clock.advance(const Duration(seconds: 7));
        await settle(tester);
        await tester.pump(const Duration(milliseconds: 500)); // sayfa kapanış geçişi

        expect(find.text('İkinci sayfa'), findsNothing);
        expect(env.state.authStatus, AuthStatus.unauthenticated);
        expect(env.state.storageError, isNotNull, reason: 'depo zaman aşımı yüzeye çıkar (belirteç sızıntısı sessiz değil)');

        await tester.tap(find.byKey(const Key('push_page')));
        await settle(tester);
        await tester.tap(find.byKey(const Key('do_logout')));
        await settle(tester);
        expect(find.text('Çıkış Yapılsın mı?'), findsOneWidget);
        await tester.tap(find.byKey(const Key('btn_logout_cancel')));
        await settle(tester);
      },
    );
  });

  // ---------------------------------------------------------------------------------------------
  // PF-43: Wi-Fi paneli / kurtarma sihirbazı
  // ---------------------------------------------------------------------------------------------
  group('Wi-Fi kurtarma: askıdaki yerel anahtar hazırlığı taramayı kilitlemez (PF-43)', () {
    bool checkEnabled(WidgetTester tester) =>
        tester.widget<OutlinedButton>(find.byKey(const Key('btn_wifi_check'))).onPressed != null;

    testWidgets(
      'WifiProvisionPanel: onDeviceChecked hiç dönmezse 3 sn sonra tarama başlar ve düğme açılır',
      (tester) async {
        final env = e2Env(role: 'owner');
        final dev = FakeWifiDevice();
        final never = Completer<void>(); // çağıran (anahtar hazırlığı) takıldı
        var calls = 0;
        await pumpApp(
          tester,
          state: env.state,
          size: const Size(800, 2200),
          child: Scaffold(
            body: SingleChildScrollView(
              child: WifiProvisionPanel(
                api: dev.client(env.clock),
                clock: env.clock,
                onDeviceChecked: (_) {
                  calls++;
                  return never.future;
                },
              ),
            ),
          ),
        );

        await tester.tap(find.byKey(const Key('btn_wifi_check')));
        await tester.pump();
        await tester.pump();
        expect(calls, 1);
        expect(dev.scanRequests, 0, reason: 'çağıran bitmeden (3 sn dolmadan) taranmaz');
        expect(checkEnabled(tester), isFalse, reason: 'kontrol sürerken düğme pasif');

        env.clock.advance(const Duration(seconds: 2));
        await tester.pump();
        expect(dev.scanRequests, 0, reason: '3 sn dolmadı');

        await advanceUntil(tester, env.clock, () => dev.scanRequests >= 1);
        await advanceUntil(tester, env.clock, () => shown('wifi_network_list') || shown('wifi_scan_error'));

        expect(dev.scanRequests, greaterThanOrEqualTo(1), reason: 'çağıran askıda kalsa da tarama başladı');
        expect(shown('wifi_network_list'), isTrue);
        expect(checkEnabled(tester), isTrue, reason: 'düğme yeniden etkin: panel sonsuza dek "kontrol ediliyor" kalmadı');
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'WifiProvisionPanel: çağıran hata verirse (askı değil) davranış değişmez: anahtarsız devam, tarama başlar',
      (tester) async {
        final env = e2Env(role: 'owner');
        final dev = FakeWifiDevice();
        await pumpApp(
          tester,
          state: env.state,
          size: const Size(800, 2200),
          child: Scaffold(
            body: SingleChildScrollView(
              child: WifiProvisionPanel(
                api: dev.client(env.clock),
                clock: env.clock,
                onDeviceChecked: (_) async => throw StateError('anahtar hazırlanamadı'),
              ),
            ),
          ),
        );
        await tester.tap(find.byKey(const Key('btn_wifi_check')));
        await tester.pump();
        await tester.pump();
        await advanceUntil(tester, env.clock, () => shown('wifi_network_list') || shown('wifi_scan_error'));
        expect(shown('wifi_network_list'), isTrue);
        expect(tester.takeException(), isNull);
      },
    );

    test(
      'WifiRecoveryDialog.readCachedKey: depo okuması takılırsa (servis sınırı olmasa da) 3 sn sonra null döner; '
      'normalde anahtarı verir; depo hatasında null',
      () async {
        final store = InMemorySecureStore();
        // Servis düzeyi süre sınırı (PF-02) BİLEREK devre dışı: yalnızca bu paketin 3 sn sınırı sınanır.
        final storage = FakeStorage(memory: store, opTimeout: const Duration(days: 365));
        final env = e2Env(authenticated: false, storage: storage);
        await storage.saveLocalKey(kDeviceUid, kDeviceKey);
        expect(await WifiRecoveryDialog.readCachedKey(env.state, kDeviceUid), kDeviceKey, reason: 'normal okuma');

        store.hangReads = Completer<void>(); // Keystore okuması takıldı
        var done = false;
        String? result = 'bekleniyor';
        unawaited(WifiRecoveryDialog.readCachedKey(env.state, kDeviceUid).then((value) {
          result = value;
          done = true;
        }));
        await env.clock.elapse(const Duration(seconds: 2));
        expect(done, isFalse, reason: '3 sn dolmadı');
        await env.clock.elapse(const Duration(seconds: 2));
        expect(done, isTrue, reason: 'okuma sonsuza dek beklenmez');
        expect(result, isNull, reason: 'anahtarsız (AP kaynaklı) yolla devam');

        store.hangReads = null;
        store.failReads = true; // depo hatası: yutulur, null
        expect(await WifiRecoveryDialog.readCachedKey(env.state, kDeviceUid), isNull);
      },
    );
  });

  // ---------------------------------------------------------------------------------------------
  // PF-50: katıl diyaloğu uzun işlem
  // ---------------------------------------------------------------------------------------------
  group('JoinHomeDialog: uzun işlemde ilerleme ve 25 sn sonra "Kapat" (PF-50)', () {
    Future<(E2Env, _JoinCloud, Opened<bool>)> openAtConfirm(WidgetTester tester) async {
      late final _JoinCloud cloud;
      final env = envWith((clock) => cloud = _JoinCloud(clock: clock), role: null);
      final opened = await openFromHost<bool>(tester, env.state, (context) => JoinHomeDialog.show(context));
      await typeInto(tester, 'field_join_code', 'AHBU-AB12CD34EF');
      await tapKey(tester, 'btn_join_continue');
      expect(find.byKey(const Key('btn_join_confirm')), findsOneWidget, reason: 'onay adımına geçildi');
      return (env, cloud, opened);
    }

    testWidgets(
      'onay sürerken belirgin ilerleme gösterilir; 25 sn dolmadan "Kapat" YOKTUR, 25 sn sonra çıkar; kapatılınca '
      'işlem arka planda biter ve sonuç bildirilir',
      (tester) async {
        final (env, cloud, opened) = await openAtConfirm(tester);
        final gate = cloud.joinGate = Completer<void>();

        await tester.tap(find.byKey(const Key('btn_join_confirm')));
        await settle(tester);

        expect(cloud.joinCodes, <String>['AHBU-AB12CD34EF']);
        expect(find.byKey(const Key('join_busy_notice')), findsOneWidget, reason: 'belirgin ilerleme (yalnız düğme içi küçük çark değil)');
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        expect(find.byKey(const Key('btn_join_close_pending')), findsNothing, reason: '25 sn dolmadı');
        expect(tester.widget<TextButton>(find.byKey(const Key('btn_join_back'))).onPressed, isNull, reason: 'meşgulken geri yok');

        env.clock.advance(const Duration(seconds: 24));
        await settle(tester);
        expect(find.byKey(const Key('btn_join_close_pending')), findsNothing, reason: '24 sn: henüz erken');

        env.clock.advance(const Duration(seconds: 2));
        await settle(tester);
        expect(find.byKey(const Key('btn_join_close_pending')), findsOneWidget, reason: '25 sn sonra "Kapat" çıkar');
        expect(noticeText(tester, 'join_busy_notice'), contains('gecikiyor'));

        await tapKey(tester, 'btn_join_close_pending');
        expect(find.byType(JoinHomeDialog), findsNothing, reason: 'diyalog kapandı');
        expect(opened.done, isTrue);
        expect(opened.result, isFalse, reason: 'sonuç bilinmiyor: "katıldı" denmez');

        // İstek arka planda tamamlanır: sonuç diyalog kapalıyken de kullanıcıya bildirilir.
        gate.complete();
        await settle(tester);
        expect(find.text('Eve katıldınız.'), findsOneWidget, reason: 'başarı iletisi SnackBar ile bildirildi');
        expect(tester.takeException(), isNull);
      },
    );

    // Erişilebilirlik: dar ekran + büyük yazı ölçeğinde ilerleme bildirimi ve "Kapat" düğmesi taşmadan çizilir.
    for (final (size, scale) in const <(Size, double)>[(Size(360, 640), 2.0), (Size(320, 568), 1.5), (Size(320, 568), 2.0)]) {
      testWidgets('${size.width.toInt()}x${size.height.toInt()}, yazı ölçeği $scale: ilerleme + "Kapat" taşmaz', (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        late final _JoinCloud cloud;
        final env = envWith((clock) => cloud = _JoinCloud(clock: clock), role: null);
        await openFromHost<bool>(tester, env.state, size: size, (context) => JoinHomeDialog.show(context));
        await typeInto(tester, 'field_join_code', 'AHBU-AB12CD34EF');
        await tapKey(tester, 'btn_join_continue');
        cloud.joinGate = Completer<void>();

        await tapKey(tester, 'btn_join_confirm');
        expect(find.byKey(const Key('join_busy_notice')), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'ilerleme bildirimi');

        env.clock.advance(const Duration(seconds: 26));
        await settle(tester);
        expect(find.byKey(const Key('btn_join_close_pending')), findsOneWidget);
        expect(tester.takeException(), isNull, reason: '"Kapat" ve uzun bildirim metni');
      });
    }

    testWidgets('işlem 25 sn içinde biterse "Kapat" hiç görünmez ve diyalog başarıyla kapanır', (tester) async {
      final (env, cloud, opened) = await openAtConfirm(tester);
      final gate = cloud.joinGate = Completer<void>();

      await tester.tap(find.byKey(const Key('btn_join_confirm')));
      await settle(tester);
      expect(find.byKey(const Key('join_busy_notice')), findsOneWidget);

      env.clock.advance(const Duration(seconds: 10));
      gate.complete();
      await settle(tester);

      expect(find.byKey(const Key('btn_join_close_pending')), findsNothing);
      expect(find.byType(JoinHomeDialog), findsNothing);
      expect(opened.result, isTrue);

      // Zamanlayıcı iptal edildi: süre dolsa da kapanmış diyalogda hata oluşmaz.
      env.clock.advance(const Duration(seconds: 60));
      await settle(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('kapatılan diyalogda geç gelen HATA da bildirilir (sessiz kaybolmaz)', (tester) async {
      final (env, cloud, _) = await openAtConfirm(tester);
      final gate = cloud.joinGate = Completer<void>();
      cloud.joinError = apiError(410, 'Bu davet kodu daha önce kullanılmış.', code: 'GONE');

      await tester.tap(find.byKey(const Key('btn_join_confirm')));
      await settle(tester);
      env.clock.advance(const Duration(seconds: 26));
      await settle(tester);
      await tapKey(tester, 'btn_join_close_pending');
      expect(find.byType(JoinHomeDialog), findsNothing);

      gate.complete();
      await settle(tester);
      expect(find.text('Bu kodun süresi dolmuş veya daha önce kullanılmış. Yeni bir kod isteyin.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

/// Katılım isteği yavaş/takılı olabilen sahte bulut (`joinHome` kapısı).
class _JoinCloud extends E2Cloud {
  _JoinCloud({super.clock});

  Completer<void>? joinGate;

  @override
  Future<JoinHomeResult> joinHome(String code) async {
    final gate = joinGate;
    if (gate != null) {
      calls.add('joinHome');
      joinCodes.add(code);
      await gate.future;
      final error = joinError;
      if (error != null) throw error;
      return joinResult;
    }
    return super.joinHome(code);
  }
}
