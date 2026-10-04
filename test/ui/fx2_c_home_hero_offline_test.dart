import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/dashboard/home_hero.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/support.dart';
import 'e1_helpers.dart';

/// D16 (DAIRE-02 / DAIRE-K1) ölçütü hero için de geçerli: pano KESİN çevrimdışıyken (bulutta `devicePresence ==
/// offline`; doğrudan kipte cihaza ulaşılamıyor) lamba/panjur durumu son bilinendir. Hero bunu kesin gibi sunmaz:
/// "Açık lamba" ve "Hareketli panjur" sayaçları çizilmez (durum şeridindeki "veri yok" gösterimiyle tutarlı), ev
/// silüetinin pencereleri sönük kalır. "Kontrol noktası" (yapılandırma sayısı) durumdan bağımsızdır, kalır.
void main() {
  Future<void> flush(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  HouseSilhouettePainter painter(WidgetTester tester) => tester
      .widgetList<CustomPaint>(find.descendant(of: byKeyName('home_hero'), matching: find.byType(CustomPaint)))
      .map((w) => w.painter)
      .whereType<HouseSilhouettePainter>()
      .single;

  group('bulut', () {
    testWidgets('pano çevrimdışı açılışta: lamba/panjur sayacı yok, pencereler sönük; kontrol noktası kalır', (tester) async {
      final h = await pumpReady(tester, scaffolded(const HomeHero()), endpoints: litEndpoints(), deviceOnline: false);
      expect(h.state.devicePresence, DevicePresence.offline);
      expect(h.state.openLightsCount, 3, reason: 'son bilinen uç nokta verisi hâlâ 3 açık lamba sayar');

      expect(find.text('Açık lamba'), findsNothing);
      expect(find.text('Hareketli panjur'), findsNothing);
      expect(find.text('Kontrol noktası'), findsOneWidget);
      expect(painter(tester).lit, 0, reason: 'son bilinen yanık pencere kesin gibi çizilmez');
    });

    testWidgets('çevrimiçi -> çevrimdışı -> çevrimiçi: sayaç ve yanan pencereler geri gelir', (tester) async {
      final h = await pumpReady(tester, scaffolded(const HomeHero()), endpoints: litEndpoints());
      expect(find.text('Açık lamba'), findsOneWidget);
      expect(painter(tester).lit, 3);

      h.mqtt.emitPresence(false);
      await flush(tester);
      expect(find.text('Açık lamba'), findsNothing);
      expect(painter(tester).lit, 0);

      h.mqtt.emitPresence(true);
      await flush(tester);
      expect(find.text('Açık lamba'), findsOneWidget);
      expect(painter(tester).lit, 3);
    });

    testWidgets('durum BİLİNMİYORKEN (kesin çevrimdışı değil) sayaç görünmeye devam eder', (tester) async {
      final h = await pumpReady(tester, scaffolded(const HomeHero()), endpoints: litEndpoints());
      h.state.setPresenceForTesting(DevicePresence.unknown);
      await flush(tester);
      expect(find.text('Açık lamba'), findsOneWidget);
      expect(painter(tester).lit, 3);
    });

    testWidgets('dar ekranda ve büyük yazıda çevrimdışı hero taşmadan çizilir', (tester) async {
      await pumpReady(tester, scaffolded(const HomeHero()),
          endpoints: litEndpoints(), deviceOnline: false, size: const Size(340, 900), textScale: 1.6);
      expect(find.text('Kontrol noktası'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('doğrudan (LAN) mod', () {
    testWidgets('cihaza ulaşılamayınca sayaç gizlenir, pencereler söner', (tester) async {
      final h = await anonymousLocalHarness();
      addTearDown(h.dispose);
      var reachable = true;
      h.directMock.on('GET', '/api/status', (request) {
        if (!reachable) throw http.ClientException('erişilemiyor');
        return jsonResponse(<String, dynamic>{
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
        });
      });
      await tester.runAsync(() => h.state.setHost('192.168.1.20'));
      await pumpPage(tester, h.state, scaffolded(const HomeHero()));
      expect(find.text('Açık lamba'), findsOneWidget);
      expect(painter(tester).lit, 2);

      reachable = false;
      await tester.runAsync(() => h.state.refresh());
      await flush(tester);
      expect(h.state.connState, ConnectionStateEnum.offline);
      expect(find.text('Açık lamba'), findsNothing);
      expect(painter(tester).lit, 0);
    });
  });
}
