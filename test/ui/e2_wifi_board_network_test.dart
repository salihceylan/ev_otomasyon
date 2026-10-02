import 'package:ev_otomasyon/services/board_network_binding.dart';
import 'package:ev_otomasyon/ui/pages/wifi_recovery_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'e2_support.dart';
import 'e2_wifi_support.dart';

/// Wi-Fi Kurulum & Kurtarma Sihirbazı + pano ağına yönlenme (Android; WP-NET): yönergenin yumuşatılması,
/// bağlama başarısızken ağ hatasına eklenen ipucu ve sihirbaz bitince bağlamanın bırakılması. Bağlama SAHTE
/// (`FakeBoardNetworkBinding`); gerçek Android cihazda DOĞRULANMADI.
const String _hintNotOnNetwork =
    'Telefon pano kurulum ağına (AHBU-…) bağlı görünmüyor: Wi-Fi ayarlarından panonun ağına bağlanın.';
const String _hintNoRoute = 'Pano ağına yönlenme kurulamadı: mobil veriyi kapatıp yeniden deneyin.';

void main() {
  late FakeBoardNetworkBinding fake;

  setUp(() {
    fake = FakeBoardNetworkBinding();
    BoardNetworkBinding.overrideForTesting(fake);
  });

  tearDown(() => BoardNetworkBinding.overrideForTesting(null));

  Future<Opened<void>> openDialog(WidgetTester tester, E2Env env) => openFromHost<void>(
        tester,
        env.state,
        (context) => WifiRecoveryDialog.show(context),
      );

  Future<void> testConnection(WidgetTester tester, E2Env env) async {
    await tester.tap(find.byKey(const Key('btn_wifi_check')));
    await tester.pump();
    await tester.pump();
    await advanceUntil(tester, env.clock, () => shown('wifi_network_list') || shown('wifi_scan_error') || shown('wifi_check_error'));
  }

  group('yönerge (Adım 1/4): mobil veri', () {
    testWidgets('Android (bağlama destekli): "mobil veri açık kalabilir; uygulama pano ağını otomatik kullanır"', (tester) async {
      fake.supported = true;
      final env = e2Env(authenticated: false);
      await openDialog(tester, env);

      final text = textOf(tester, 'wifi_step_ap_text');
      expect(text, contains(BoardNetworkBinding.mobileDataAdvice));
      expect(text, contains('Mobil veri açık kalabilir; uygulama pano ağını otomatik kullanır. Bağlantı kurulamazsa mobil veriyi kapatıp yeniden deneyin.'));
      expect(text, isNot(contains('gerekirse mobil veriyi')), reason: 'eski "kapatın" yönergesi yumuşatıldı');
      expect(text, contains('4. Telefon "internet yok" uyarısı verirse bağlantıyı koruyun.'));
      expect(text, contains('5. Bağlandıktan sonra bu ekrana dönüp'), reason: 'sonraki madde yerinde');
    });

    testWidgets('Android dışı (iOS/masaüstü/web: bağlama yok): eski yönerge AYNEN kalır', (tester) async {
      fake.supported = false;
      final env = e2Env(authenticated: false);
      await openDialog(tester, env);

      final text = textOf(tester, 'wifi_step_ap_text');
      expect(text, contains('4. Telefon "internet yok" uyarısı verirse bağlantıyı koruyun (gerekirse mobil veriyi geçici olarak kapatın).'));
      expect(text, isNot(contains('Mobil veri açık kalabilir')));
    });
  });

  group('bağlama başarısızken ağ hatasına ipucu eklenir', () {
    testWidgets('bağlantı testi: telefon pano ağında değil (notOnBoardNetwork) -> ipucu; metin teknik değil', (tester) async {
      fake.status = BoardNetworkStatus.notOnBoardNetwork;
      final env = e2Env(authenticated: false);
      final dev = FakeWifiDevice()..statusDown = true;

      await http.runWithClient(() async {
        await openDialog(tester, env);
        await testConnection(tester, env);
      }, () => dev.api.client);

      final error = textOf(tester, 'wifi_check_error');
      expect(error, startsWith('Pano bulunamadı.'));
      expect(error, endsWith(_hintNotOnNetwork));
      expect(error, isNot(contains('Exception')));
      expect(fake.events.first, 'acquire:192.168.4.1');
      expect(fake.activeLeases, 0, reason: 'başarısız bağlamada da kira bırakılır');
    });

    testWidgets('bağlantı testi: yönlenme kurulamadı (timeout) -> "mobil veriyi kapatıp yeniden deneyin" ipucu', (tester) async {
      fake.status = BoardNetworkStatus.timeout;
      final env = e2Env(authenticated: false);
      final dev = FakeWifiDevice()..statusDown = true;

      await http.runWithClient(() async {
        await openDialog(tester, env);
        await testConnection(tester, env);
      }, () => dev.api.client);

      expect(textOf(tester, 'wifi_check_error'), endsWith(_hintNoRoute));
    });

    testWidgets('bağlama BAŞARILI iken aynı ağ hatasında ipucu YOK (pano gerçekten kapalı/ulaşılamıyor)', (tester) async {
      fake.status = BoardNetworkStatus.bound;
      final env = e2Env(authenticated: false);
      final dev = FakeWifiDevice()..statusDown = true;

      await http.runWithClient(() async {
        await openDialog(tester, env);
        await testConnection(tester, env);
      }, () => dev.api.client);

      final error = textOf(tester, 'wifi_check_error');
      expect(error, startsWith('Pano bulunamadı.'));
      expect(error, isNot(contains('AHBU-…')));
      expect(error, isNot(contains('yönlenme')));
    });

    testWidgets('tarama ve gönderme hataları da ipucunu taşır; bağlama kirası her çağrıdan sonra bırakılmıştır', (tester) async {
      final env = e2Env(authenticated: false);
      final dev = FakeWifiDevice();

      await http.runWithClient(() async {
        await openDialog(tester, env);
        await testConnection(tester, env); // bağlama başarılı: ağ listesi gelir
        expect(shown('wifi_network_list'), isTrue);

        fake.status = BoardNetworkStatus.notOnBoardNetwork;
        dev.api.on('POST', '/api/wifi/connect', (r) => throw http.ClientException('yok'));
        await typeInto(tester, 'field_wifi_ssid', 'EvAgi');
        await typeInto(tester, 'field_wifi_password', 'yeni-evagi-sifresi');
        await tester.tap(find.byKey(const Key('btn_wifi_submit')));
        await tester.pump();
        await tester.pump();
        await advanceUntil(tester, env.clock, () => shown('wifi_form_error'));
        expect(textOf(tester, 'wifi_form_error'), endsWith(_hintNotOnNetwork));

        dev.api.on('GET', '/api/wifi/scan', (r) => throw http.ClientException('yok'));
        await tester.tap(find.byKey(const Key('btn_wifi_scan')));
        await tester.pump();
        await tester.pump();
        await advanceUntil(tester, env.clock, () => shown('wifi_scan_error'));
        expect(textOf(tester, 'wifi_scan_error'), endsWith(_hintNotOnNetwork));
      }, () => dev.api.client);

      expect(fake.activeLeases, 0);
    });
  });

  group('sihirbaz yaşam döngüsü: kira sızmaz', () {
    testWidgets('uçtan uca (test -> tarama -> yükleme -> başarı): bekleme tek kira; bitince hiçbir kira açık kalmaz', (tester) async {
      final env = e2Env(authenticated: false);
      final dev = FakeWifiDevice();

      await http.runWithClient(() async {
        await openDialog(tester, env);
        await testConnection(tester, env);
        await tester.tap(find.byKey(const Key('wifi_network_0')));
        await tester.pump();
        await typeInto(tester, 'field_wifi_password', 'yeni-evagi-sifresi');
        await tester.tap(find.byKey(const Key('btn_wifi_submit')));
        await tester.pump();
        await tester.pump();

        dev.connectState = 'success';
        await advanceUntil(tester, env.clock, () => shown('wifi_result_success'));
      }, () => dev.api.client);

      expect(fake.activeLeases, 0, reason: 'sihirbaz bitince süreç varsayılan ağa döner (bulut normale döner)');
      expect(fake.releaseCount, fake.acquireCount, reason: 'her kira bırakıldı');
      // Gönderme + sonuç bekleme TEK kira altında: 1 (test) + 1 (tarama) + 1 (gönder+bekle) = 3 kira.
      expect(fake.acquireCount, 3);
      expect(fake.hosts.toSet(), <String>{'192.168.4.1'});
      expect(env.cloud.calls, isEmpty, reason: 'bulut çağrısı yok');
    });

    testWidgets('sonuç beklenirken sihirbaz kapatılırsa bekleme iptal olur ve kira bırakılır', (tester) async {
      final env = e2Env(authenticated: false);
      final dev = FakeWifiDevice();

      await http.runWithClient(() async {
        await openDialog(tester, env);
        await testConnection(tester, env);
        await tester.tap(find.byKey(const Key('wifi_network_0')));
        await tester.pump();
        await typeInto(tester, 'field_wifi_password', 'yeni-evagi-sifresi');
        await tester.tap(find.byKey(const Key('btn_wifi_submit')));
        await tester.pump();
        await tester.pump();
        await advanceUntil(tester, env.clock, () => shown('wifi_waiting'));
        expect(fake.activeLeases, 1, reason: 'bekleme sürerken kira tutulur');
        expect(dev.pollCalls, greaterThan(0), reason: 'bekleme yoklaması gerçekten çalışıyor (test boş geçmemeli)');

        final close = find.byKey(const Key('btn_close'));
        await tester.ensureVisible(close);
        await tester.tap(close);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500)); // kapanış geçişi
        expect(find.byType(WifiRecoveryDialog), findsNothing, reason: 'sihirbaz kapandı');

        // Bekleme döngüsü bir sonraki yoklamada (1,5 sn) iptali görür: zaman aşımına (40 sn) KADAR beklenmez ve
        // kapanıştan sonra panoya YENİ yoklama isteği gönderilmez.
        final pollsAtClose = dev.pollCalls;
        env.clock.advance(const Duration(seconds: 2));
        await tester.pump();
        await tester.pump();
        expect(dev.pollCalls, pollsAtClose, reason: 'iptalden sonra yeni wifi/status yoklaması yapılmadı');
      }, () => dev.api.client);

      expect(fake.activeLeases, 0, reason: 'diyalog kapanınca bekleme durdu ve kira 2 sn içinde bırakıldı');
      expect(fake.releaseCount, fake.acquireCount);
      expect(tester.takeException(), isNull);
    });
  });
}
