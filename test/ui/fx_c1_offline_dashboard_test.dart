import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/dashboard/apartment_dashboard.dart';
import 'package:ev_otomasyon/ui/dashboard/peace_banner.dart';
import 'package:ev_otomasyon/ui/dashboard/status_pills.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/support.dart';
import 'e1_helpers.dart';

/// DAIRE-02 / DAIRE-K1 (D16): pano KESİN çevrimdışıyken (bulutta `devicePresence == offline`; doğrudan kipte cihaza
/// ulaşılamıyor) açık lamba sayısı bilinmez: uç nokta / cihaz durumu son bilinen değerdir.
///
/// * Huzur bandı ("N lamba açık kaldı." + "Hepsini Kapat") GİZLENİR: kesin iddia + sunucuda 409 ile düşecek düğme yok.
/// * Durum şeridinin sayaç hapları kesin "Tüm Işıklar Kapalı" / "N Işık Açık" DEMEZ: doğrudan kipteki "veri yok"
///   gösterimi (sayaç hapları hiç çizilmez, yalnız sistem hapı kalır) bulut çevrimdışı için de kullanılır.
void main() {
  Future<void> flush(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// Uç noktalar: tüm lambalar (ve priz) kapalı.
  List<EndpointModel> darkEndpoints() => testEndpoints();

  group('Huzur bandı: pano kesin çevrimdışıyken gizlenir', () {
    testWidgets('bulut: pano çevrimdışı açılışta son bilinen 3 açık lambaya rağmen band YOK', (tester) async {
      final h = await pumpReady(tester, scaffolded(const PeaceBanner()), endpoints: litEndpoints(), deviceOnline: false);
      expect(h.state.devicePresence, DevicePresence.offline);
      expect(h.state.openLightsCount, 3, reason: 'son bilinen uç nokta verisi hâlâ 3 açık lamba sayar');
      expect(byKeyName('banner_peace'), findsNothing);
      expect(find.textContaining('lamba açık kaldı'), findsNothing);
      expect(byKeyName('btn_close_all_lights'), findsNothing, reason: 'sunucuda 409 DEVICE_OFFLINE ile düşecek düğme yok');
    });

    testWidgets('bulut: pano çevrimdışı olunca band kalkar, yeniden çevrimiçi olunca geri gelir', (tester) async {
      final h = await pumpReady(tester, scaffolded(const PeaceBanner()), endpoints: litEndpoints());
      expect(find.text('3 lamba açık kaldı.'), findsOneWidget);

      h.mqtt.emitPresence(false);
      await flush(tester);
      expect(h.state.devicePresence, DevicePresence.offline);
      expect(byKeyName('banner_peace'), findsNothing);

      h.mqtt.emitPresence(true);
      await flush(tester);
      expect(find.text('3 lamba açık kaldı.'), findsOneWidget);
    });

    testWidgets('bulut: durum BİLİNMİYORKEN (kesin çevrimdışı değil) band görünmeye devam eder', (tester) async {
      final h = await pumpReady(tester, scaffolded(const PeaceBanner()), endpoints: litEndpoints());
      h.state.setPresenceForTesting(DevicePresence.unknown);
      await flush(tester);
      expect(byKeyName('banner_peace'), findsOneWidget, reason: 'yalnız KESİN çevrimdışılık gizler');
    });
  });

  group('Durum şeridi: pano kesin çevrimdışıyken ışık/panjur sayaçları kesin konuşmaz', () {
    testWidgets('bulut: açık lambalar varken pano çevrimdışı -> "N Işık Açık" YOK, sistem hapı "Pano çevrimdışı"', (tester) async {
      await pumpReady(tester, scaffolded(const DashboardStatusBar()), endpoints: litEndpoints(), deviceOnline: false);
      expect(find.text('3 Işık Açık'), findsNothing);
      expect(find.text('Tüm Işıklar Kapalı'), findsNothing);
      expect(find.text('Panjurlar Sabit'), findsNothing);
      expect(byKeyName('pill_system'), findsOneWidget);
      expect(find.text('Pano çevrimdışı'), findsOneWidget);
    });

    testWidgets('bulut: tüm lambalar kapalıyken pano çevrimdışı -> kesin "Tüm Işıklar Kapalı" YOK', (tester) async {
      await pumpReady(tester, scaffolded(const DashboardStatusBar()), endpoints: darkEndpoints(), deviceOnline: false);
      expect(find.text('Tüm Işıklar Kapalı'), findsNothing, reason: 'bilinmeyen durum kesin bilgi gibi sunulmaz');
      expect(find.text('Panjurlar Sabit'), findsNothing);
      expect(byKeyName('pill_system'), findsOneWidget);
    });

    testWidgets('bulut: çevrimdışı -> çevrimiçi geçişinde sayaçlar geri gelir', (tester) async {
      final h = await pumpReady(tester, scaffolded(const DashboardStatusBar()), endpoints: litEndpoints());
      expect(find.text('3 Işık Açık'), findsOneWidget);

      h.mqtt.emitPresence(false);
      await flush(tester);
      expect(find.text('3 Işık Açık'), findsNothing);

      h.mqtt.emitPresence(true);
      await flush(tester);
      expect(find.text('3 Işık Açık'), findsOneWidget);
      expect(find.text('Panjurlar Sabit'), findsOneWidget);
    });
  });

  group('Doğrudan (LAN) mod: cihaza ulaşılamayınca son bilinen durum kesin sunulmaz', () {
    Map<String, dynamic> lanStatus() => <String, dynamic>{
          'device': 'AHBU-S3-TEST01',
          'name': 'Salon Panosu',
          'fw': '1.1.0',
          'provisioned': true,
          'wifi_connected': true,
          'wifi_sta_ssid': 'EvAgi',
          'wifi_sta_ip': '192.168.1.20',
          'ip': '192.168.1.20',
          'child_lock': false,
          'relays': <Map<String, dynamic>>[
            <String, dynamic>{'id': 1, 'name': 'Avize', 'type': 0, 'state': true},
            <String, dynamic>{'id': 2, 'name': 'Spot', 'type': 0, 'state': true},
          ],
          'shutters': <dynamic>[],
          'dis': <Map<String, dynamic>>[],
        };

    /// Girişsiz yerel mod: cihaz önce yanıt verir (durum alınır), sonra [reachable] kapatılınca ulaşılamaz olur.
    Future<({StateHarness h, void Function(bool) setReachable})> localHarness(WidgetTester tester) async {
      final h = await anonymousLocalHarness();
      addTearDown(h.dispose);
      var reachable = true;
      h.directMock.on('GET', '/api/status', (request) {
        if (!reachable) throw http.ClientException('erişilemiyor');
        return jsonResponse(lanStatus());
      });
      await tester.runAsync(() => h.state.setHost('192.168.1.20'));
      return (h: h, setReachable: (bool v) => reachable = v);
    }

    Future<void> goOffline(WidgetTester tester, ({StateHarness h, void Function(bool) setReachable}) r) async {
      r.setReachable(false);
      await tester.runAsync(() => r.h.state.refresh());
      await flush(tester);
      expect(r.h.state.connState, ConnectionStateEnum.offline);
      expect(r.h.state.status, isNotNull, reason: 'son bilinen cihaz durumu ekranda kalır');
    }

    testWidgets('huzur bandı: cihaz yanıt verirken görünür, ulaşılamayınca gizlenir', (tester) async {
      final r = await localHarness(tester);
      await pumpPage(tester, r.h.state, scaffolded(const PeaceBanner()));
      expect(find.text('2 lamba açık kaldı.'), findsOneWidget);

      await goOffline(tester, r);
      expect(byKeyName('banner_peace'), findsNothing);
    });

    testWidgets('durum şeridi: ulaşılamayınca "N Işık Açık" yerine yalnız sistem hapı ("Cihaza ulaşılamıyor")', (tester) async {
      final r = await localHarness(tester);
      await pumpPage(tester, r.h.state, scaffolded(const DashboardStatusBar()));
      expect(find.text('2 Işık Açık'), findsOneWidget);

      await goOffline(tester, r);
      expect(find.text('2 Işık Açık'), findsNothing);
      expect(find.text('Tüm Işıklar Kapalı'), findsNothing);
      expect(find.text('Cihaza ulaşılamıyor'), findsOneWidget);
    });
  });

  group('Pano (bütün ekran)', () {
    testWidgets('bulut çevrimdışı: çevrimdışı uyarısı var, çelişen "N lamba açık kaldı" bandı ve sayaç hapı yok', (tester) async {
      await pumpReady(tester, const Scaffold(body: ApartmentDashboard()),
          endpoints: litEndpoints(), deviceOnline: false, size: const Size(800, 3000));
      expect(byKeyName('notice_device_offline'), findsOneWidget);
      expect(byKeyName('banner_peace'), findsNothing);
      expect(find.text('3 Işık Açık'), findsNothing);
    });
  });
}
