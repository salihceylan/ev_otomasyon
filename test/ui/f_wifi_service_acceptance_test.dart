import 'package:ev_otomasyon/services/automation_api_service.dart';
import 'package:ev_otomasyon/ui/pages/service_mode_page.dart';
import 'package:ev_otomasyon/ui/pages/wifi_recovery_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart' as sup;
import 'f_support.dart';
import 'f_widget_support.dart';

/// Kabul testi (canlı test listesi Aşama 16.1-16.5): **girişsiz** ve **internetsiz** bir servis sorumlusu,
/// servis panelindeki "Pano Wi-Fi & Modem Kurulumu" kartından sihirbazı açar; telefon panonun kurulum
/// ağındayken (WPA2, anahtarsız AP erişimi — CONTRACTS §3d) bağlantıyı sınar, ağı listeden seçer, şifreyi yazar,
/// gönderir ve **sonucu bekler**. Sunucuya hiçbir istek gitmez, pano `X-Device-Key` HİÇ almaz.

bool exists(String key) => find.byKey(Key(key)).evaluate().isNotEmpty;

/// Saati ilerleterek ve kare üreterek [cond] gerçekleşene kadar bekler.
Future<void> pumpAdvancing(WidgetTester tester, FakeDevice device, bool Function() cond, {String? reason}) async {
  for (var i = 0; i < 400; i++) {
    await tester.pump(const Duration(milliseconds: 10));
    if (cond()) return;
    device.clock.advance(const Duration(milliseconds: 250));
    await tester.pump();
  }
  fail('Koşul gerçekleşmedi${reason == null ? '' : ': $reason'}');
}

void main() {
  group('Wi-Fi servis akışı (girişsiz, internetsiz, anahtarsız)', () {
    late sup.FakeClock clock;
    late FakeDevice device;
    late ServiceFakeCloud cloud;
    late sup.StateHarness h;

    setUp(() {
      clock = sup.FakeClock();
      device = FakeDevice(clock: clock);
      cloud = ServiceFakeCloud(clock: clock)..internetUp = false; // telefon panonun kurulum ağında: internet YOK
      h = sup.StateHarness(clock: clock, cloud: cloud);
    });
    tearDown(() {
      device.dispose();
      h.dispose();
    });

    AutomationApiService Function(String host) factory() =>
        (host) => AutomationApiService(baseUrl: '', client: device.api.client, clock: clock)..updateHost(host);

    Future<void> openFromPanel(WidgetTester tester) async {
      await sup.pumpApp(
        tester,
        child: ServiceModePage(deviceApiFactory: factory()),
        state: h.state,
        size: const Size(900, 3200),
      );
      await settle(tester);
      expect(h.state.isAuthenticated, isFalse, reason: 'giriş yapılmamış');
      await tapKey(tester, 'btn_wifi_setup_wizard');
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(WifiRecoveryDialog), findsOneWidget);
    }

    testWidgets('bağlantı testi yeşil; ağlar anahtarsız taranır; seçilen ağa şifre yazılıp gönderilir ve YALNIZ pano bağlandığında başarı gösterilir',
        (tester) async {
      await openFromPanel(tester);

      // 16.2: Pano Bağlantısını Test Et
      await tapKey(tester, 'btn_wifi_check');
      await pumpAdvancing(tester, device, () => exists('wifi_network_0'), reason: 'ağ listesi gelmedi');
      expect(find.textContaining('Pano ile bağlantı kuruldu'), findsOneWidget);

      // 16.4: listeden ağ seç -> şifre kutusuna geç
      await tapKey(tester, 'wifi_network_0');
      await tester.pump();
      await typeKey(tester, 'field_wifi_password', kHomeWifiPass);

      // 16.5: gönder -> sonucu bekle
      await tapKey(tester, 'btn_wifi_submit');
      await pumpAdvancing(tester, device, () => exists('wifi_result_success'), reason: 'pano bağlandı sonucu gelmedi');

      expect(device.wifiConnected, isTrue);
      expect(device.staIp, kLanIp);
      expect(cloud.calls, isEmpty, reason: 'internetsiz kurulum ağında sunucuya hiçbir istek atılmaz');
      expect(device.keyHeaderHosts, isEmpty, reason: 'pano X-Device-Key HİÇ almadı: anahtarsız AP erişimi');
      expect(h.cloud.calls.where((c) => c.startsWith('localKey')), isEmpty);
    });

    testWidgets('yanlış Wi-Fi şifresi: başarı gösterilmez, neden yazılır; doğru şifreyle tekrar denenince bağlanır', (tester) async {
      await openFromPanel(tester);
      await tapKey(tester, 'btn_wifi_check');
      await pumpAdvancing(tester, device, () => exists('wifi_network_0'));

      await tapKey(tester, 'wifi_network_0');
      await tester.pump();
      await typeKey(tester, 'field_wifi_password', 'yanlis-parola-1');
      await tapKey(tester, 'btn_wifi_submit');
      await pumpAdvancing(tester, device, () => exists('wifi_result_failed'), reason: 'hata sonucu gelmedi');
      expect(exists('wifi_result_success'), isFalse, reason: 'başarı yalnızca pano bağlandığında');
      expect(device.wifiConnected, isFalse);
      expect(find.textContaining('şifresi hatalı'), findsOneWidget);

      await tapKey(tester, 'btn_wifi_retry');
      await tester.pump();
      await typeKey(tester, 'field_wifi_password', kHomeWifiPass);
      await tapKey(tester, 'btn_wifi_submit');
      await pumpAdvancing(tester, device, () => exists('wifi_result_success'));
      expect(device.wifiConnected, isTrue);
      expect(cloud.calls, isEmpty);
      expect(device.keyHeaderHosts, isEmpty);
    });

    testWidgets('telefon kurulum ağında değilse (pano bulunamazsa) anlaşılır açıklama gelir; sunucuya yine istek atılmaz', (tester) async {
      device.apReachable = false; // telefon panonun ağında değil
      await openFromPanel(tester);
      await tapKey(tester, 'btn_wifi_check');
      await pumpAdvancing(tester, device, () => exists('wifi_check_error'), reason: 'bağlantı hatası açıklanmadı');
      expect(find.textContaining('Pano bulunamadı'), findsOneWidget);
      expect(find.textContaining('Exception'), findsNothing);
      expect(cloud.calls, isEmpty);
    });
  });
}
