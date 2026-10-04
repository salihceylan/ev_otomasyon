import 'dart:async';

import 'package:ev_otomasyon/models/automation_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/dashboard/apartment_dashboard.dart';
import 'package:ev_otomasyon/ui/dashboard/close_all_lights_button.dart';
import 'package:ev_otomasyon/ui/dashboard/connection_status.dart';
import 'package:ev_otomasyon/ui/dashboard/dashboard_states.dart';
import 'package:ev_otomasyon/ui/dashboard/endpoint_sections.dart';
import 'package:ev_otomasyon/ui/dashboard/module_badge.dart';
import 'package:ev_otomasyon/ui/dashboard/status_pills.dart';
import 'package:ev_otomasyon/ui/theme/app_theme.dart';
import 'package:ev_otomasyon/ui/theme/tokens.dart';
import 'package:ev_otomasyon/ui/widgets/di_status_pill.dart';
import 'package:ev_otomasyon/ui/widgets/orb/orb.dart';
import 'package:ev_otomasyon/ui/widgets/quick_scenario_bar.dart';
import 'package:ev_otomasyon/ui/widgets/relay_switch_card.dart';
import 'package:ev_otomasyon/ui/widgets/shutter_card.dart';
import 'package:ev_otomasyon/ui/widgets/surface_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/support.dart';
import 'e1_helpers.dart';

/// WP-F1 (pano + kartlar eleştirmen bulguları) davranış kilitleri: bağlantı rozeti (aktif daire yokken), durum şeridi
/// (veri yokken sayaç hapı yok; tek hap yüksekliği + 48 dp hedef), ızgara dengesi, senaryo satırı (kaydırma ipucu +
/// kırpmasız gölge + büyük yazıda genişleme), ortak rozet / kilit bileşenleri, tek orb'lu darbe kartı, durum kartlarının
/// geniş ekranda sınırlı genişliği ve tema düğme stilleri (shape/backgroundColor geçersiz kılması yok).
void main() {
  Widget body() => const Scaffold(body: ApartmentDashboard());

  /// Giriş yapmış ama henüz ev yüklenmemiş durum (REST çağrıları testte denetlenir).
  Future<StateHarness> loggedInHarness({void Function(StateHarness h)? configure}) async {
    final h = StateHarness();
    h.state
      ..setCurrentUserForTesting(const UserModel(id: 'user-1', email: 'a@b.c', fullName: 'Ayşe Yılmaz', role: 'user'))
      ..setAuthStatusForTesting(AuthStatus.authenticated);
    configure?.call(h);
    return h;
  }

  Map<String, dynamic> lanStatus() => <String, dynamic>{
        'device_name': 'Pano',
        'ip': '192.168.1.30',
        'wifi_connected': true,
        'wifi_sta_ssid': 'EvAg',
        'wifi_sta_rssi': -55,
        'uptime_sec': 100,
        'child_lock': false,
        'relays': <Map<String, dynamic>>[
          <String, dynamic>{'id': 1, 'name': 'Avize', 'type': 0, 'state': true},
        ],
        'shutters': <Map<String, dynamic>>[],
        'dis': <Map<String, dynamic>>[],
      };

  /// Doğrudan (LAN) mod: önce durum alınır, sonra cihaz [status] yanıtı verir (401 = anahtar gerekli, 423 = kilitli).
  Future<StateHarness> directHarness(WidgetTester tester, int status, Map<String, dynamic> response) async {
    final h = (await tester.runAsync(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final h = StateHarness();
      h.state
        ..setCurrentUserForTesting(const UserModel(id: 'u', email: 'a@b.c', fullName: 'Ayşe Yılmaz', role: 'user'))
        ..setAuthStatusForTesting(AuthStatus.authenticated)
        ..setHomesForTesting(<HomeModel>[testHome()]);
      h.directMock.on('GET', '/api/status', (r) => jsonResponse(lanStatus()));
      await h.state.setMode(AppMode.direct);
      await h.state.setHost('192.168.1.30');
      h.direct.localKey = 'devicekey-1234';
      await h.state.refresh();
      h.directMock.on('GET', '/api/status', (r) => jsonResponse(response, status: status));
      await h.clock.elapse(const Duration(seconds: 5));
      return h;
    }))!;
    addTearDown(h.dispose);
    return h;
  }

  Future<void> flush(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  // ---------------------------------------------------------------------------------------------
  group('Bağlantı rozeti: aktif daire yokken ekranla çelişmez', () {
    test('ev listesi yüklenirken "Bağlanıyor…" kalır (gerçekten yükleniyor)', () async {
      final gate = Completer<void>();
      final h = await loggedInHarness(configure: (h) => h.cloud.fetchHomesGate = gate);
      addTearDown(h.dispose);
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      unawaited(h.state.fetchHomes());
      final badge = connectionBadgeOf(h.state);
      expect(badge.level, ConnectionLevel.connecting);
      expect(badge.label, 'Bağlanıyor…');
    });

    test('ev listesi HATASI: "Sunucuya ulaşılamıyor" (çevrimdışı seviye); "Bağlanıyor…" DEĞİL', () async {
      final h = await loggedInHarness(configure: (h) => h.cloud.fetchHomesError = kServerError);
      addTearDown(h.dispose);
      await h.state.fetchHomes();
      final badge = connectionBadgeOf(h.state);
      expect(badge.level, ConnectionLevel.offline);
      expect(badge.label, 'Sunucuya ulaşılamıyor');
      expect(badge.label, isNot(contains('Bağlanıyor')));
    });

    test('başarılı BOŞ ev listesi: bulut bağlı, "Daire yok"', () async {
      final h = await loggedInHarness();
      addTearDown(h.dispose);
      await h.state.fetchHomes();
      final badge = connectionBadgeOf(h.state);
      expect(badge.level, ConnectionLevel.ready);
      expect(badge.label, 'Bulut bağlı');
      expect(badge.detail, 'Daire yok');
    });

    test('aktif daire varken rozet cihaz durumundan gelir (değişmedi): "Sistem Hazır"', () async {
      final h = await e1Ready();
      addTearDown(h.dispose);
      final badge = connectionBadgeOf(h.state);
      expect(badge.level, ConnectionLevel.ready);
      expect(badge.label, 'Sistem Hazır');
    });

    test('misafir erişimi sona ermişse rozet "Erişim süresi doldu" der ("Bağlanıyor…" değil)', () async {
      final h = await e1Ready(home: guestHome(hours: 1, name: 'Yazlık'));
      addTearDown(h.dispose);
      expect(connectionBadgeOf(h.state).label, 'Sistem Hazır', reason: 'süre dolmadan: normal durum');
      h.clock.advance(const Duration(hours: 2));
      final badge = connectionBadgeOf(h.state);
      expect(badge.level, ConnectionLevel.locked);
      expect(badge.label, 'Erişim süresi doldu');
      expect(badge.label, isNot(contains('Bağlanıyor')));
    });

    test('ConnectionBadge.family: seviye -> aile eşlemesi (nokta/kenar şekil rengi)', () {
      AccentFamily of(ConnectionLevel l) => ConnectionBadge(level: l, label: 'x', detail: 'y').family;
      expect(of(ConnectionLevel.ready), AppFamilies.emerald);
      expect(of(ConnectionLevel.degraded), AppFamilies.amber);
      expect(of(ConnectionLevel.needsKey), AppFamilies.amber);
      expect(of(ConnectionLevel.locked), AppFamilies.amber);
      expect(of(ConnectionLevel.offline), AppFamilies.rose);
      expect(of(ConnectionLevel.connecting), AppFamilies.slate);
    });
  });

  // ---------------------------------------------------------------------------------------------
  group('Durum şeridi: sayaç hapları yalnız sayılacak veri varken', () {
    testWidgets('cihaz verisi varken ışık / panjur / sistem hapları görünür', (tester) async {
      await pumpReady(tester, scaffolded(const DashboardStatusBar()));
      expect(find.text('Tüm Işıklar Kapalı'), findsOneWidget);
      expect(find.text('Panjurlar Sabit'), findsOneWidget);
      expect(find.text('Sistem Hazır'), findsOneWidget);
    });

    testWidgets('hiç cihaz yokken sayaç hapları YOK (sistem hapı kalır)', (tester) async {
      await pumpReady(tester, scaffolded(const DashboardStatusBar()), endpoints: <EndpointModel>[]);
      expect(find.text('Tüm Işıklar Kapalı'), findsNothing, reason: 'veri yokken "kapalı" kesin bilgi gibi sunulmaz');
      expect(find.text('Panjurlar Sabit'), findsNothing);
      expect(byKeyName('pill_system'), findsOneWidget);
    });

    testWidgets('doğrudan mod, cihaz durumu YOKKEN (anahtar gerekli): yalnız sistem hapı; ışık/panjur sayaçları gizli', (tester) async {
      final h = await directHarness(tester, 401, <String, dynamic>{'error': 'unauthorized'});
      await pumpPage(tester, h.state, body());
      await flush(tester);
      expect(h.state.status, isNull);
      expect(find.text('Tüm Işıklar Kapalı'), findsNothing);
      expect(find.text('Panjurlar Sabit'), findsNothing);
      expect(find.text('Cihaz anahtarı gerekli'), findsWidgets, reason: 'sistem hapı anlamlıdır ve kalır');
      expect(byKeyName('pill_system'), findsOneWidget);
    });

    testWidgets('hap yükseklikleri tek: dokunulmaz hap 36 dp, dokunulabilir hap görsel 36 + saydam pay = 48 dp', (tester) async {
      final h = await pumpReady(tester, scaffolded(const DashboardStatusBar()), endpoints: litEndpoints());
      h.mqtt.emitStateJson(stateJson(childLock: true));
      await flush(tester);

      final chip = tester.getSize(byKeyName('chip_child_lock'));
      expect(chip.height, StatusPill.kTouchTarget, reason: 'dokunma hedefi 48 dp');

      final plain = find.byWidgetPredicate((w) => w is StatusPill && w.onTap == null);
      expect(plain, findsWidgets);
      for (var i = 0; i < plain.evaluate().length; i++) {
        expect(tester.getSize(plain.at(i)).height, StatusPill.kHeight, reason: 'dokunulmaz hap görsel yükseklikte (şişirilmez)');
      }
      // Dokunulabilir hapın İÇ görseli de aynı 36 dp'dir (48 dp'nin içinde ortalı).
      final inner = tester.getSize(
        find.descendant(of: byKeyName('chip_child_lock'), matching: find.byType(Container)).first,
      );
      expect(inner.height, StatusPill.kHeight);
    });

    testWidgets('çocuk kilidi rozeti ham Colors.amber DEĞİL, amber ailesidir', (tester) async {
      final h = await pumpReady(tester, scaffolded(const DashboardStatusBar()));
      h.mqtt.emitStateJson(stateJson(childLock: true));
      await flush(tester);
      expect(tester.widget<StatusPill>(byKeyName('chip_child_lock')).color, AppFamilies.amber.base);
    });
  });

  // ---------------------------------------------------------------------------------------------
  group('CardGrid: kart sayısına göre dengeli sütun', () {
    test('columnsFor: genişlik kuralı + kart sayısı + yetim kart (4 kart 3 sütunda 3+1 olmaz)', () {
      expect(CardGrid.columnsFor(1200), 3, reason: 'sayı verilmezse yalnız genişlik kuralı');
      expect(CardGrid.columnsFor(1200, count: 1), 1, reason: 'tek kart 3 sütunun 1\'ine sıkışmaz');
      expect(CardGrid.columnsFor(1200, count: 2), 2);
      expect(CardGrid.columnsFor(1200, count: 4), 2, reason: '2x2: yetim "Priz" kartı kalmaz');
      expect(CardGrid.columnsFor(1200, count: 5), 3);
      expect(CardGrid.columnsFor(1200, count: 6), 3);
      expect(CardGrid.columnsFor(768, count: 1), 1);
      expect(CardGrid.columnsFor(768, count: 4), 2);
      expect(CardGrid.columnsFor(328, count: 5), 1, reason: 'telefon tek sütun');
      expect(CardGrid.columnsFor(328, count: 0), 1);
    });

    // Kartlar mevcut genişliği DOLDURUR (eskiden 560 dp'de kesilirdi: lamba ızgarası hero / huzur bandı / senaryo satırından
    // ~68 dp kısa bitiyor, tek panjur kartı sola yaslı 560 dp'de duruyordu). BİLİNÇLİ güncelleme: "1200 dp'ye gerilmez
    // (maxItemWidth)" sözleşmesi, tüm bölümlerin AYNI sağ kenarda bitmesi sözleşmesine dönüştü (2. tur eleştirmen bulgusu
    // r2_dashboard / r2_cross: geniş ekranda sağ kenar hizasızlığı).
    Future<void> pumpGrid(WidgetTester tester, double width, int count) => pumpReady(
          tester,
          Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: CardGrid(children: [for (var i = 0; i < count; i++) SizedBox(key: Key('card_$i'), height: 40)]),
              ),
            ),
          ),
          size: Size(width + 80, 800),
        );

    testWidgets('geniş ekranda tek kart TAM genişliktedir (sola yaslı 560 dp\'lik kart değil)', (tester) async {
      await pumpGrid(tester, 1200, 1);
      expect(tester.getSize(byKeyName('card_0')).width, 1200);
    });

    testWidgets('masaüstü (1200 dp) iki / dört kart: iki sütun, sütunlar eşit, sağ kenar içerik kenarında', (tester) async {
      for (final count in [2, 4]) {
        await pumpGrid(tester, 1200, count);
        final first = tester.getRect(byKeyName('card_0'));
        final second = tester.getRect(byKeyName('card_1'));
        expect(first.width, (1200 - CardGrid.gap) / 2, reason: '$count kart: eşit sütun');
        expect(second.width, first.width, reason: '$count kart');
        expect(second.right, 1200, reason: '$count kart: ızgara tüm içerik genişliğini doldurur');
        expect(second.left - first.right, CardGrid.gap, reason: '$count kart');
      }
    });

    testWidgets('üç sütun (1200 dp, 5 kart) ve tablet (768 dp, 3 kart: 2 sütun) sağ kenarı doldurur', (tester) async {
      await pumpGrid(tester, 1200, 5);
      expect(tester.getRect(byKeyName('card_2')).right, closeTo(1200, 0.001));
      expect(tester.getSize(byKeyName('card_0')).width, closeTo((1200 - 2 * CardGrid.gap) / 3, 0.001));

      await pumpGrid(tester, 768, 3);
      expect(tester.getRect(byKeyName('card_1')).right, closeTo(768, 0.001));
      expect(tester.getTopLeft(byKeyName('card_2')).dx, 0, reason: 'üçüncü kart ikinci satıra iner');
    });
  });

  // ---------------------------------------------------------------------------------------------
  group('Hızlı senaryolar: kaydırma ipucu, kırpmasız gölge, büyük yazı', () {
    test('fits / scrollTileWidth hesapları', () {
      expect(QuickScenarioBar.fits(768), isTrue, reason: '5 x 136 + 4 x 8 = 712 <= 768: satır eşit paylaşır');
      expect(QuickScenarioBar.fits(328), isFalse);
      expect(QuickScenarioBar.fits(768, scale: 1.5), isFalse, reason: 'büyük yazıda kutucuk genişler: kaydırma kipi');
      final tile = QuickScenarioBar.scrollTileWidth(328);
      expect(tile, inInclusiveRange(QuickScenarioBar.tileMinWidth, QuickScenarioBar.tileMaxWidth));
      // 2 tam kutucuk + 1 aralık, görünümden en az ~24 dp pay bırakır: sonraki kutucuk görünür.
      expect(2 * tile + QuickScenarioBar.tileGap, lessThanOrEqualTo(328 - 24));
      expect(QuickScenarioBar.scrollTileWidth(328, scale: 1.5), greaterThan(tile), reason: 'büyük yazıda kutucuk büyür');
    });

    testWidgets('telefonda üçüncü kutucuk görünür (peek) ve kaydırma görünümü KIRPMAZ', (tester) async {
      await pumpReady(tester, scaffolded(const QuickScenarioBar()), size: const Size(360, 800));
      final third = tester.getTopLeft(byKeyName('card_scenario_night')).dx;
      expect(third, lessThanOrEqualTo(360 - 20), reason: 'üçüncü kutucuğun en az 20 dp\'si görünür: kaydırılabilirlik ipucu');
      expect(third, greaterThan(16 + 2 * QuickScenarioBar.tileMinWidth));

      final scroll = tester.widget<SingleChildScrollView>(
        find.descendant(of: find.byType(QuickScenarioBar), matching: find.byType(SingleChildScrollView)).first,
      );
      expect(scroll.scrollDirection, Axis.horizontal);
      expect(scroll.clipBehavior, Clip.none, reason: 'gölge sert kenarla kırpılıp "gölge levhası" oluşturmasın');
    });

    testWidgets('800 dp tablette 5 kutucuk satırı eşit paylaşır (sağda sert kesilmiş kutucuk yok)', (tester) async {
      await pumpReady(tester, scaffolded(const QuickScenarioBar()), size: const Size(800, 800));
      for (final s in kQuickScenarios) {
        final right = tester.getTopRight(byKeyName('card_scenario_${s.id}')).dx;
        expect(right, lessThanOrEqualTo(800 - 16 + 0.5), reason: s.id);
      }
      expect(find.byType(SingleChildScrollView).evaluate().where((e) => (e.widget as SingleChildScrollView).scrollDirection == Axis.horizontal), isEmpty);
    });

    testWidgets('başlık ortak SectionHeader (mini orb + sayı rozeti) ve kutucuk yazıları >= 12 sp', (tester) async {
      await pumpReady(tester, scaffolded(const QuickScenarioBar()));
      expect(find.text('Hızlı Senaryolar'), findsOneWidget);
      expect(find.text('5 Senaryo'), findsOneWidget);
      expect(find.descendant(of: find.byType(QuickScenarioBar), matching: find.byType(SectionHeader)), findsOneWidget);
      for (final s in kQuickScenarios) {
        for (final t in tester.widgetList<Text>(find.descendant(of: byKeyName('card_scenario_${s.id}'), matching: find.byType(Text)))) {
          expect(t.style!.fontSize!, greaterThanOrEqualTo(AppTouch.minFontSize), reason: '${s.id}: ${t.data}');
        }
      }
    });
  });

  // ---------------------------------------------------------------------------------------------
  group('Kartlar: ortak rozet, kilit, tek orb, soluk çevrimdışı orb, tema izi', () {
    const ext = RelayItem(id: 11, name: 'Teras Aydınlatma', type: 0, state: true);
    const impulse = RelayItem(id: 5, name: 'Bahçe Kapısı Açıcı', type: 3, state: false);
    const lamp = RelayItem(id: 1, name: 'Salon Avize', type: 0, state: false);

    RelayVm rv({bool on = false, bool offline = false, bool locked = false, bool canControl = true}) =>
        (isOn: on, name: 'Kart', pending: false, offline: offline, canControl: canControl, locked: locked);

    ShutterVm sv({
      bool moving = false,
      int direction = 0,
      bool offline = false,
      bool isExt = false,
      bool locked = false,
    }) =>
        (
          pos: 40,
          moving: moving,
          direction: direction,
          target: null,
          name: 'Salon Panjur',
          isExt: isExt,
          pending: false,
          offline: offline,
          canControl: true,
          locked: locked,
        );

    testWidgets('"CH 3" ve "RS485" aynı ModuleBadge: >= 12 sp, hap şekli', (tester) async {
      await pumpReady(
        tester,
        scaffolded(
          Column(children: [
            RelayCardView(relay: ext, vm: rv(on: true)),
            ShutterCardView(pair: 5, vm: sv(isExt: true)),
          ]),
        ),
      );
      expect(find.byType(ModuleBadge), findsNWidgets(2));
      for (final text in ['CH 3', 'RS485']) {
        final style = tester.widget<Text>(find.text(text)).style!;
        expect(style.fontSize!, greaterThanOrEqualTo(AppTouch.minFontSize), reason: text);
        expect(style.fontWeight, FontWeight.w700, reason: text);
      }
      final decoration = tester
          .widget<Container>(find.descendant(of: find.byType(ModuleBadge).first, matching: find.byType(Container)).first)
          .decoration as BoxDecoration;
      expect(decoration.borderRadius, BorderRadius.circular(AppRadius.pill), reason: 'rozetler hap (stadium)');
    });

    testWidgets('çocuk kilidi: kart başına TEK Icons.lock_outline (LockBadge içinde) — röle ve panjur', (tester) async {
      await pumpReady(tester, scaffolded(RelayCardView(relay: lamp, vm: rv(locked: true))));
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
      expect(find.byType(LockBadge), findsOneWidget);
      await pumpReady(tester, scaffolded(ShutterCardView(pair: 1, vm: sv(locked: true))));
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
      expect(find.byType(LockBadge), findsOneWidget);
    });

    testWidgets('darbe rölesi: TEK orb (sol, "Tetikle" etiketi altında); kimsesiz ikinci rozet yok', (tester) async {
      await pumpReady(tester, scaffolded(RelayCardView(relay: impulse, vm: rv())));
      expect(find.byType(OrbButton), findsOneWidget);
      expect(find.byType(OrbIconBadge), findsNothing, reason: 'eskiden sağdaki düğmenin aynısı etkileşimsiz rozet vardı');
      expect(byKeyName('btn_relay_impulse_5'), findsOneWidget);
      final orbX = tester.getCenter(byKeyName('btn_relay_impulse_5')).dx;
      expect(orbX, lessThan(tester.getCenter(find.text('Kart')).dx), reason: 'orb solda (kart adının solunda)');
      final label = tester.widget<Text>(find.text('Tetikle'));
      expect(label.style!.color, AppTheme.getTextPrimary(tester.element(find.text('Tetikle'))),
          reason: 'etiket rengi panjur orb etiketleriyle aynı (ana metin)');
    });

    testWidgets('röle kartının gövdesi SurfaceCard.onTap ile basma geri bildirimi verir (InkWell opak kartın arkasında kalırdı)',
        (tester) async {
      await pumpReady(
        tester,
        scaffolded(
          Column(children: [
            RelayCardView(relay: lamp, vm: rv()),
            RelayCardView(relay: lamp.copyWithId(2), vm: rv(canControl: false)),
            RelayCardView(relay: impulse, vm: rv()),
          ]),
        ),
      );
      expect(tester.widget<SurfaceCard>(byKeyName('card_relay_1')).onTap, isNotNull);
      expect(tester.widget<SurfaceCard>(byKeyName('card_relay_2')).onTap, isNull, reason: 'yetkisiz: dokunuş yok');
      expect(tester.widget<SurfaceCard>(byKeyName('card_relay_5')).onTap, isNull, reason: 'darbe çıkışı kazara tetiklenmesin');
    });

    testWidgets('panjur "Kapanıyor…" metni amber DEĞİL, hareket yönü (sky) rengindedir; "Açılıyor…" emerald', (tester) async {
      await pumpReady(
        tester,
        scaffolded(
          Column(children: [
            ShutterCardView(pair: 1, vm: sv(moving: true, direction: 2)),
            ShutterCardView(pair: 2, vm: sv(moving: true, direction: 1)),
          ]),
        ),
      );
      final context = tester.element(find.text('Kapanıyor…'));
      final closing = tester.widget<Text>(find.text('Kapanıyor…')).style!.color;
      expect(closing, AppTheme.readableFamily(context, AppFamilies.sky));
      expect(closing, isNot(AppTheme.warningText(context)));
      expect(tester.widget<Text>(find.text('Açılıyor…')).style!.color, AppTheme.readableFamily(context, AppFamilies.emerald));
    });

    testWidgets('panjur Aç/Kapat simgeleri DOLU üçgen (iconBuilder), Durdur karesi Material simgesi', (tester) async {
      await pumpReady(tester, scaffolded(ShutterCardView(pair: 1, vm: sv())));
      expect(tester.widget<OrbButton>(byKeyName('btn_shutter_up_1')).iconBuilder, isNotNull);
      expect(tester.widget<OrbButton>(byKeyName('btn_shutter_down_1')).iconBuilder, isNotNull);
      expect(tester.widget<OrbButton>(byKeyName('btn_shutter_stop_1')).icon, Icons.stop_rounded);
      expect(find.byIcon(Icons.arrow_upward_rounded), findsNothing, reason: 'ince çizgi ok kalmadı');
    });

    testWidgets('çevrimdışı: orblar SOLUK (dimmed) ama dokunulabilir; çevrimiçiyken soluk değil', (tester) async {
      await pumpReady(
        tester,
        scaffolded(
          Column(children: [
            ShutterCardView(pair: 1, vm: sv(offline: true)),
            RelayCardView(relay: ext, vm: rv(on: true, offline: true)),
            ShutterCardView(pair: 2, vm: sv()),
          ]),
        ),
      );
      for (final key in ['btn_shutter_up_1', 'btn_shutter_stop_1', 'btn_shutter_down_1']) {
        final orb = tester.widget<OrbButton>(byKeyName(key));
        expect(orb.dimmed, isTrue, reason: key);
        expect(orb.onTap, isNotNull, reason: '$key: komut çevrimdışıyken de gönderilebilir; orb dokunulabilir kalır');
      }
      expect(tester.widget<OrbToggle>(byKeyName('switch_relay_11')).dimmed, isTrue);
      expect(tester.widget<OrbButton>(byKeyName('btn_shutter_up_2')).dimmed, isFalse);
    });

    testWidgets('panjur kaydırıcısı pasif izi TEMADAN gelir (kartta yerel inactiveTrackColor geçersiz kılması yok)', (tester) async {
      await pumpReady(tester, scaffolded(ShutterCardView(pair: 1, vm: sv())));
      final context = tester.element(byKeyName('slider_shutter_1'));
      expect(SliderTheme.of(context).inactiveTrackColor, Theme.of(context).sliderTheme.inactiveTrackColor);
    });
  });

  // ---------------------------------------------------------------------------------------------
  group('Durum kartları: geniş ekranda sınırlı genişlik, tema düğme stili, renk dili', () {
    testWidgets('dairesiz karşılama (1280 dp): sütun <= 600 dp, CTA\'lar <= 420 dp ve ortalı; düğmelerde shape/renk geçersiz kılma YOK',
        (tester) async {
      final h = await loggedInHarness();
      addTearDown(h.dispose);
      await tester.runAsync(() => h.state.fetchHomes());
      await pumpPage(tester, h.state, body(), size: const Size(1280, 900));

      expect(tester.getSize(byKeyName('view_homeless')).width, lessThanOrEqualTo(kDashboardStateMaxWidth));
      for (final key in ['btn_join_code', 'btn_scan_qr']) {
        final width = tester.getSize(byKeyName(key)).width;
        expect(width, lessThanOrEqualTo(kDashboardCtaMaxWidth), reason: key);
        expect(width, greaterThan(250), reason: '$key: çubuk değil ama düğme gibi geniş');
        expect(tester.getCenter(byKeyName(key)).dx, closeTo(640, 1), reason: '$key ortalı');
      }
      final join = tester.widget<FilledButton>(byKeyName('btn_join_code'));
      expect(join.style?.shape, isNull, reason: 'tema stadium; r14 dikdörtgen geçersiz kılması kalktı');
      expect(join.style?.backgroundColor, isNull, reason: 'tema gradyanı; düz mavi dolgu geçersiz kılması kalktı');
      final scan = tester.widget<OutlinedButton>(byKeyName('btn_scan_qr'));
      expect(scan.style?.shape, isNull);
      expect(scan.style?.side, isNull);
    });

    testWidgets('cihaz eşleme karşılama kartı (ev sahibi, 1280 dp): durum şeridi YOK, CTA tema ElevatedButton, <= 420 dp', (tester) async {
      await pumpReady(tester, body(), role: 'owner', endpoints: <EndpointModel>[], size: const Size(1280, 900));
      expect(byKeyName('card_welcome_claim'), findsOneWidget);
      expect(byKeyName('status_bar'), findsNothing, reason: 'cihaz yokken "Sistem Hazır" kurulum CTA\'sıyla yarışmaz');
      expect(tester.getSize(byKeyName('card_welcome_claim')).width, lessThanOrEqualTo(kDashboardStateMaxWidth));
      expect(tester.getSize(byKeyName('btn_scan_qr')).width, lessThanOrEqualTo(kDashboardCtaMaxWidth));
      final claim = tester.widget<ElevatedButton>(byKeyName('btn_scan_qr'));
      expect(claim.style, isNull, reason: 'tema yüzeyi: backgroundColor / shape / elevation geçersiz kılması yok');
    });

    testWidgets('ev listesi hatası kartı (1280 dp) <= 600 dp ve ROSE (kalıcı hata)', (tester) async {
      final h = await loggedInHarness(configure: (h) => h.cloud.fetchHomesError = kServerError);
      addTearDown(h.dispose);
      await tester.runAsync(() => h.state.fetchHomes());
      await pumpPage(tester, h.state, body(), size: const Size(1280, 900));
      expect(tester.getSize(byKeyName('error_card')).width, lessThanOrEqualTo(kDashboardStateMaxWidth));
      expect(tester.widget<StateCard>(byKeyName('error_card')).accent, AppFamilies.rose.base);
      expect(tester.widget<FilledButton>(byKeyName('btn_retry')).onPressed, isNotNull);
    });

    testWidgets('doğrudan mod "anahtar gerekli": amber uyarı kartı; birincil eylem "Ayarları aç", "Yeniden dene" ikincil', (tester) async {
      final h = await directHarness(tester, 401, <String, dynamic>{'error': 'unauthorized'});
      // Telefon genişliği: eylemler alt alta dizilir, sıra görünür (birincil önce).
      await pumpPage(tester, h.state, body(), size: const Size(360, 900));
      await flush(tester);
      expect(byKeyName('error_card'), findsOneWidget);
      expect(tester.widget<StateCard>(byKeyName('error_card')).accent, AppFamilies.amber.base);
      expect(tester.widget<FilledButton>(byKeyName('btn_open_settings')).onPressed, isNotNull, reason: 'birincil');
      expect(tester.widget<OutlinedButton>(byKeyName('btn_retry')).onPressed, isNotNull, reason: 'ikincil');
      expect(
        tester.getTopLeft(byKeyName('btn_open_settings')).dy,
        lessThan(tester.getTopLeft(byKeyName('btn_retry')).dy),
        reason: 'birincil eylem önce gelir',
      );
    });

    testWidgets('doğrudan mod "cihaza ulaşılamıyor": amber; "Yeniden dene" birincil kalır (FilledButton)', (tester) async {
      final h = await anonymousLocalHarness();
      addTearDown(h.dispose);
      h.directMock.on('GET', '/api/status', (request) => throw StateError('erişilemiyor'));
      await tester.runAsync(() => h.state.setHost('192.168.1.20'));
      await pumpPage(tester, h.state, body());
      await flush(tester);
      expect(tester.widget<StateCard>(byKeyName('error_card')).accent, AppFamilies.amber.base);
      expect(tester.widget<FilledButton>(byKeyName('btn_retry')).onPressed, isNotNull);
    });

    testWidgets('hata kartı eylemleri dar ekranda alt alta TAM genişlikte (hizalı)', (tester) async {
      final h = await directHarness(tester, 401, <String, dynamic>{'error': 'unauthorized'});
      await pumpPage(tester, h.state, body(), size: const Size(360, 900));
      await flush(tester);
      expect(tester.getSize(byKeyName('btn_open_settings')).width, tester.getSize(byKeyName('btn_retry')).width);
      expect(tester.getTopLeft(byKeyName('btn_open_settings')).dx, tester.getTopLeft(byKeyName('btn_retry')).dx);
    });
  });

  // ---------------------------------------------------------------------------------------------
  group('Hero: açık tema kontrastı ve geniş yerleşim', () {
    testWidgets('açık temada amber sayaç (3 açık lamba) AA kontrastlıdır (>= 4.5:1; eskiden ~2.9:1)', (tester) async {
      await pumpReady(tester, body(), endpoints: litEndpoints(), themeMode: ThemeMode.light);
      final color = tester.widget<Text>(find.descendant(of: byKeyName('home_hero'), matching: find.text('3'))).style!.color!;
      final tokens = SurfaceTokens.light;
      expect(AppTheme.contrastRatio(color, tokens.cardTop), greaterThanOrEqualTo(4.5));
      expect(AppTheme.contrastRatio(color, tokens.cardBottom), greaterThanOrEqualTo(4.5));
    });

    testWidgets('geniş ekranda (1280 dp) sayaçlar solda toplanır; 1200 dp\'ye yayılmaz', (tester) async {
      await pumpReady(tester, body(), endpoints: litEndpoints(), size: const Size(1280, 1100));
      expect(tester.getTopLeft(find.text('Kontrol noktası')).dx, lessThan(700));
    });
  });

  // ---------------------------------------------------------------------------------------------
  group('DI hapı ve "Hepsini Kapat"', () {
    testWidgets('DI hapı OPAK cam gövde (devre izi içinden görünmez), tek satır ad, >= 12 sp', (tester) async {
      await pumpReady(
        tester,
        scaffolded(
          const Wrap(children: [
            DIStatusPill(di: DIItem(id: 12, name: 'Giriş 12', state: true)),
            DIStatusPill(di: DIItem(id: 2, name: 'Giriş 2', state: false)),
          ]),
        ),
      );
      for (final id in [12, 2]) {
        final decoration = tester.widget<Container>(byKeyName('card_di_$id')).decoration as BoxDecoration;
        final gradient = decoration.gradient as LinearGradient;
        expect(gradient.colors.every((c) => c.a == 1.0), isTrue, reason: 'giriş $id: opak taban');
      }
      final nameStyle = tester.widget<Text>(find.text('Giriş 12 (ek modül)'));
      expect(nameStyle.maxLines, 1);
      for (final t in tester.widgetList<Text>(find.descendant(of: byKeyName('card_di_2'), matching: find.byType(Text)))) {
        expect(t.style!.fontSize!, greaterThanOrEqualTo(AppTouch.minFontSize));
      }
    });

    testWidgets('"Hepsini Kapat" çerçeveli varyant varsayılanı indigoAccent DEĞİL, sky ailesidir (açık tema)', (tester) async {
      await pumpReady(
        tester,
        scaffolded(const CloseAllLightsButton(filled: false)),
        themeMode: ThemeMode.light,
        endpoints: litEndpoints(),
      );
      final style = tester.widget<OutlinedButton>(byKeyName('btn_close_all_lights')).style!;
      final border = style.side!.resolve(<WidgetState>{})!.color;
      // BİLİNÇLİ güncelleme (2. tur FX-A tek ton kuralı): kenar artık elle `sky.deep@.75` değil tüm çerçeveli düğmelerle AYNI
      // `AppTheme.outlinedBorderOfColor` kuralıdır (ham renk önce ailesine oturtulur; iki temada ≥ 3:1). Varsayılan renk
      // sky olduğundan kenar, sky ailesinin tema çerçeveli düğme kenarıyla ([AppTheme.outlinedBorder]) birebir aynıdır.
      final context = tester.element(byKeyName('btn_close_all_lights'));
      expect(border, AppTheme.outlinedBorderOfColor(context, AppFamilies.sky.deep));
      expect(border, AppTheme.outlinedBorder(context, AppFamilies.sky), reason: 'tema OutlinedButton ile aynı çerçeve tonu');
      expect(AppTheme.contrastRatio(border, Colors.white), greaterThanOrEqualTo(3.0));
      expect(border, isNot(Colors.indigoAccent.withValues(alpha: 0.7)));
      final foreground = style.foregroundColor!.resolve(<WidgetState>{})!;
      expect(AppTheme.contrastRatio(foreground, AppTheme.bgLight), greaterThanOrEqualTo(4.5));
    });
  });
}

extension on RelayItem {
  /// Aynı röle, farklı kimlik (anahtar çakışmasın diye yalnız testte).
  RelayItem copyWithId(int newId) => RelayItem(id: newId, name: name, type: type, state: state);
}
