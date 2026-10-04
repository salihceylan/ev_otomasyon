import 'package:ev_otomasyon/ui/dashboard/apartment_dashboard.dart';
import 'package:ev_otomasyon/ui/dashboard/dashboard_app_bar.dart';
import 'package:ev_otomasyon/ui/dashboard/peace_banner.dart';
import 'package:ev_otomasyon/ui/dashboard/status_pills.dart';
import 'package:ev_otomasyon/ui/pages/dashboard_page.dart';
import 'package:ev_otomasyon/ui/widgets/quick_scenario_bar.dart';
import 'package:ev_otomasyon/ui/widgets/relay_switch_card.dart';
import 'package:ev_otomasyon/ui/widgets/shutter_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';
import 'e1_helpers.dart';

/// KİLİT testi (PF-04 / PF-05 / PF-06; akıcılık): cihazdan gelen `state` iletisi yalnızca DEĞİŞEN kartı
/// yeniden kurar. Kanıt `RebuildCounter` (Flutter `debugOnRebuildDirtyWidget`): ölçümsüz performans
/// iddiası yok, "bu bildirimde şu bileşenler yeniden kurulmaz" kodla sabitlenir.
///
/// Bugünkü davranış kilitlenir (kod incelemesiyle yeşil beklenir): `AutomationState` aynı iletiyi de
/// bildirir (`_applyCloudSnapshot` koşulsuz), ama kartlar/şerit/uygulama çubuğu kendi `select` değerleri
/// değişmedikçe yeniden kurulmaz. Bu testler bildirim SAYISINA bağlı değildir (PF-04 bildirimi azaltırsa da yeşil kalır).
void main() {
  /// Cihaz `state` yükü: `testEndpoints()` yerleşimi (röle 1,2,5 lamba, 6 priz; panjur çifti 2).
  Map<String, dynamic> liveState({
    Map<int, bool> relays = const <int, bool>{1: false, 2: false, 5: false, 6: false},
    bool moving = false,
    int pos = 30,
  }) =>
      stateJson(
        relays: relays,
        shutters: <Map<String, dynamic>>[
          <String, dynamic>{'pair': 2, 'pos': pos, 'moving': moving, 'dir': moving ? 1 : 0, 'target': moving ? 100 : 255},
        ],
      );

  Future<void> flush(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// Son `pumpDashboard`'ın ilk canlı iletisinde yeniden kurulan element sayısı (provider kapsamı hariç).
  var firstMessageRebuilds = 0;

  /// Provider'ın kendi kapsam elementi (her bildirimde bir kez kurulur) HARİÇ yeniden kurulan element sayısı.
  int rebuiltExceptProviderScope(RebuildCounter counter) => counter.byName.entries
      .where((e) => !e.key.startsWith('_InheritedProviderScope'))
      .fold<int>(0, (sum, e) => sum + e.value);

  /// Panoyu kurar: 400x3000 (tüm kartlar görünür), ilk canlı ileti uygulanmış, sayaç sıfırlanmış.
  /// [deviceOnline] `false`: pano başta çevrimdışı görünür; ilk canlı ileti onu çevrimiçi yapar (meşru yeniden kurulum).
  Future<({StateHarness h, RebuildCounter counter})> pumpDashboard(
    WidgetTester tester, {
    bool deviceOnline = true,
  }) async {
    final counter = RebuildCounter.install();
    final h = await pumpReady(tester, const DashboardPage(), size: const Size(400, 3000), deviceOnline: deviceOnline);

    // Kendi kendini sınar: sayaç çalışıyor ve kartlar ekranda (aksi halde "0 yeniden kurulum" boş geçerdi).
    expect(counter.of<RelaySwitchCard>(), greaterThanOrEqualTo(4), reason: 'ilk kurulum 4 röle kartını kurar');
    expect(counter.of<ShutterCard>(), greaterThanOrEqualTo(1));
    for (final key in <String>['card_relay_1', 'card_relay_2', 'card_relay_5', 'card_relay_6', 'card_shutter_2']) {
      expect(byKeyName(key), findsOneWidget, reason: key);
    }

    // İlk canlı ileti cihazı çevrimiçi yapar / uç noktaları eşitler; meşru yeniden kurulumlar BU adımda olur.
    expect(h.state.deviceOnline, deviceOnline);
    if (!deviceOnline) expect(byKeyName('notice_device_offline'), findsOneWidget, reason: 'pano başta çevrimdışı görünür');
    counter.reset();
    h.mqtt.emitStateJson(liveState());
    await flush(tester);
    expect(h.state.deviceOnline, isTrue);
    if (!deviceOnline) expect(byKeyName('notice_device_offline'), findsNothing, reason: 'ilk canlı ileti çevrimiçi yaptı');
    firstMessageRebuilds = rebuiltExceptProviderScope(counter);
    counter.reset();
    return (h: h, counter: counter);
  }

  group('aynı cihaz durumu tekrar gelince', () {
    testWidgets('10 özdeş ileti: kartlar, durum şeridi, huzur bandı, uygulama çubuğu ve pano HİÇ yeniden kurulmaz', (tester) async {
      final (:h, :counter) = await pumpDashboard(tester);

      for (var i = 0; i < 10; i++) {
        h.mqtt.emitStateJson(liveState());
        await flush(tester);
      }

      for (final type in <Type>[
        RelaySwitchCard,
        ShutterCard,
        DashboardStatusBar,
        PeaceBanner,
        DashboardAppBar,
        ApartmentDashboard,
        QuickScenarioBar,
        DashboardPage,
      ]) {
        expect(counter.ofType(type), 0, reason: '$type özdeş iletide yeniden kurulmamalı. ${counter.describe()}');
      }
      expect(rebuiltExceptProviderScope(counter), 0,
          reason: 'bildirim yağmuru hiçbir widget\'ı yeniden kurmamalı (yalnız provider kapsamı). ${counter.describe()}');
    });

    testWidgets('pano başta ÇEVRİMDIŞI iken: ilk canlı ileti çevrimiçi yapar (meşru yeniden kurulum), sonraki özdeş iletiler 0', (tester) async {
      final (:h, :counter) = await pumpDashboard(tester, deviceOnline: false);
      expect(firstMessageRebuilds, greaterThan(0),
          reason: 'ilk ileti çevrimdışı -> çevrimiçi geçişidir: arayüz güncellenmeli (kilit boş geçmesin)');

      for (var i = 0; i < 10; i++) {
        h.mqtt.emitStateJson(liveState());
        await flush(tester);
      }

      for (final type in <Type>[
        RelaySwitchCard,
        ShutterCard,
        DashboardStatusBar,
        PeaceBanner,
        DashboardAppBar,
        ApartmentDashboard,
        QuickScenarioBar,
        DashboardPage,
      ]) {
        expect(counter.ofType(type), 0, reason: '$type ilk iletiden sonra özdeş iletide yeniden kurulmamalı. ${counter.describe()}');
      }
      expect(rebuiltExceptProviderScope(counter), 0, reason: counter.describe());
    });

    testWidgets('hareket eden panjurun özdeş iletileri (aynı konum/hedef) de yeniden kurulum üretmez', (tester) async {
      final (:h, :counter) = await pumpDashboard(tester);
      h.mqtt.emitStateJson(liveState(moving: true, pos: 40));
      await flush(tester);
      await tester.pump(const Duration(seconds: 1)); // geçiş animasyonları bitsin
      counter.reset();

      for (var i = 0; i < 10; i++) {
        h.mqtt.emitStateJson(liveState(moving: true, pos: 40));
        await flush(tester);
      }

      expect(counter.of<ShutterCard>(), 0, reason: counter.describe());
      expect(counter.of<DashboardStatusBar>(), 0, reason: counter.describe());
      expect(rebuiltExceptProviderScope(counter), 0, reason: counter.describe());
    });
  });

  group('tek değer değişince yalnız ilgili bileşen yeniden kurulur', () {
    testWidgets('tek röle değişimi: RelaySwitchCard YALNIZ 1 (değişen kart); panjur, uygulama çubuğu, pano, senaryolar 0', (tester) async {
      final (:h, :counter) = await pumpDashboard(tester);

      h.mqtt.emitStateJson(liveState(relays: const <int, bool>{1: true, 2: false, 5: false, 6: false}));
      await flush(tester);

      expect(counter.of<RelaySwitchCard>(), 1, reason: counter.describe());
      expect(counter.ofKey(const ValueKey<String>('relay_1')), 1, reason: 'yeniden kurulan kart değişen röle (1) olmalı');
      for (final other in <int>[2, 5, 6]) {
        expect(counter.ofKey(ValueKey<String>('relay_$other')), 0, reason: 'röle $other değişmedi');
      }
      expect(counter.of<ShutterCard>(), 0, reason: counter.describe());
      expect(counter.of<DashboardAppBar>(), 0, reason: counter.describe());
      expect(counter.of<ApartmentDashboard>(), 0, reason: counter.describe());
      expect(counter.of<QuickScenarioBar>(), 0, reason: counter.describe());
      expect(counter.of<DashboardPage>(), 0, reason: counter.describe());
      // Açık lamba sayısı 0 -> 1 değişti: şerit ve huzur bandı BİR kez (en çok) yeniden kurulur.
      expect(counter.of<DashboardStatusBar>(), lessThanOrEqualTo(1), reason: counter.describe());
      expect(counter.of<PeaceBanner>(), lessThanOrEqualTo(1), reason: counter.describe());
      expect(find.text('AÇIK'), findsOneWidget, reason: 'değişim gerçekten ekrana yansıdı (kontrol boş geçmesin)');
    });

    testWidgets('panjur hareketi: ShutterCard YALNIZ 1; röle kartları, uygulama çubuğu, pano, senaryolar 0', (tester) async {
      final (:h, :counter) = await pumpDashboard(tester);

      h.mqtt.emitStateJson(liveState(moving: true, pos: 40));
      await flush(tester);

      expect(counter.of<ShutterCard>(), 1, reason: counter.describe());
      expect(counter.of<RelaySwitchCard>(), 0, reason: counter.describe());
      expect(counter.of<DashboardAppBar>(), 0, reason: counter.describe());
      expect(counter.of<ApartmentDashboard>(), 0, reason: counter.describe());
      expect(counter.of<QuickScenarioBar>(), 0, reason: counter.describe());
      expect(counter.of<PeaceBanner>(), 0, reason: 'açık lamba sayısı değişmedi');
      expect(counter.of<DashboardStatusBar>(), lessThanOrEqualTo(1), reason: 'hareketli panjur sayısı değişti');
      expect(find.text('1 Panjur Hareketli'), findsOneWidget, reason: 'değişim gerçekten ekrana yansıdı');
    });

    testWidgets('iki röle aynı iletide değişirse YALNIZ o iki kart yeniden kurulur', (tester) async {
      final (:h, :counter) = await pumpDashboard(tester);

      h.mqtt.emitStateJson(liveState(relays: const <int, bool>{1: true, 2: true, 5: false, 6: false}));
      await flush(tester);

      expect(counter.of<RelaySwitchCard>(), 2, reason: counter.describe());
      expect(counter.ofKey(const ValueKey<String>('relay_1')), 1);
      expect(counter.ofKey(const ValueKey<String>('relay_2')), 1);
      expect(counter.ofKey(const ValueKey<String>('relay_5')), 0);
      expect(counter.of<ShutterCard>(), 0, reason: counter.describe());
      expect(counter.of<DashboardAppBar>(), 0, reason: counter.describe());
    });
  });

  group('RebuildCounter (kilit aracının kendi sözleşmesi)', () {
    testWidgets('install/uninstall önceki kancayı geri yükler; reset sayaçları sıfırlar', (tester) async {
      final before = debugOnRebuildDirtyWidget;
      final counter = RebuildCounter.install();
      expect(debugOnRebuildDirtyWidget, isNotNull);
      expect(identical(debugOnRebuildDirtyWidget, before), isFalse);

      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Text('a'))));
      expect(counter.total, greaterThan(0), reason: 'ilk kurulum da sayılır');
      expect(counter.of<Text>(), 1);
      expect(counter.ofName('Text'), 1);
      expect(counter.byName['Text'], 1);

      counter.reset();
      expect(counter.total, 0);
      expect(counter.of<Text>(), 0);

      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Text('b'))));
      expect(counter.of<Text>(), 1, reason: 'metin değişince yeniden kurulur');

      counter.uninstall();
      expect(identical(debugOnRebuildDirtyWidget, before), isTrue);
      counter.reset();
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Text('c'))));
      expect(counter.total, 0, reason: 'kaldırılan sayaç saymaz');
    });

    testWidgets('iç içe kurulumlar zincirlenir: dıştaki de sayar, sırasız kaldırma kancayı bozmaz', (tester) async {
      final before = debugOnRebuildDirtyWidget;
      final outer = RebuildCounter.install();
      final inner = RebuildCounter.install();

      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Text('a'))));
      expect(inner.of<Text>(), 1);
      expect(outer.of<Text>(), 1, reason: 'önceki kanca zincirlenir');

      outer.uninstall(); // sırasız: iç hâlâ kurulu, kancayı geri yüklememeli
      outer.reset();
      inner.reset();
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Text('b'))));
      expect(inner.of<Text>(), 1, reason: 'iç sayaç çalışmaya devam eder');
      expect(outer.of<Text>(), 0, reason: 'kaldırılan dış sayaç saymaz');

      inner.uninstall();
      expect(identical(debugOnRebuildDirtyWidget, before), isFalse, reason: 'dış sayacın kancası zincirde kaldı (iç geri yükler)');
      debugOnRebuildDirtyWidget = before; // testin kendi temizliği
    });
  });
}
