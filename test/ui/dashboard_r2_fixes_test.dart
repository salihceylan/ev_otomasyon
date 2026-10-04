import 'package:ev_otomasyon/models/automation_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/dashboard/apartment_dashboard.dart';
import 'package:ev_otomasyon/ui/dashboard/child_lock_status.dart';
import 'package:ev_otomasyon/ui/dashboard/connection_status.dart';
import 'package:ev_otomasyon/ui/dashboard/dashboard_states.dart';
import 'package:ev_otomasyon/ui/dashboard/endpoint_sections.dart';
import 'package:ev_otomasyon/ui/dashboard/module_badge.dart';
import 'package:ev_otomasyon/ui/dashboard/status_pills.dart';
import 'package:ev_otomasyon/ui/pages/dashboard_page.dart';
import 'package:ev_otomasyon/ui/theme/app_theme.dart';
import 'package:ev_otomasyon/ui/theme/tokens.dart';
import 'package:ev_otomasyon/ui/widgets/app_pill.dart';
import 'package:ev_otomasyon/ui/widgets/orb/orb.dart';
import 'package:ev_otomasyon/ui/widgets/quick_scenario_bar.dart';
import 'package:ev_otomasyon/ui/widgets/relay_switch_card.dart';
import 'package:ev_otomasyon/ui/widgets/shutter_card.dart';
import 'package:ev_otomasyon/ui/widgets/super_user_drawer.dart';
import 'package:ev_otomasyon/ui/widgets/surface_card.dart';
import 'package:ev_otomasyon/ui/widgets/user_profile_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';
import 'e1_helpers.dart';
import 'e2_support.dart';

/// 2. tur eleştirmen bulguları (WP-FX-C: pano + kartlar + konsollar) davranış kilitleri:
///
/// * ızgara mevcut genişliği doldurur, tüm bölümler aynı sağ kenarda biter; panjur kartı geniş kipte iki panel;
/// * bağlantı hapı metni etiketi tekrarlamaz; görünmez çocuk kilidi rozeti şeritte yuva tüketmez;
/// * ev değiştirici oku başlığın hemen yanında; avatar rol ailesinde; menü ⋮ diskinin altında açılır;
/// * lamba AÇIK durumu opak hap (yerel kontrast), kart adı kesilmez, çevrimdışı panjur iz/başparmak sönük;
/// * konsol bölüm başlıkları SectionHeader; profil: orb satır rozetleri + AppChip diliyle tema çipleri.
void main() {
  Future<void> flush(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  const lamp = RelayItem(id: 1, name: 'Salon Avize', type: 0, state: false);

  RelayVm rv({bool on = false, bool offline = false, String name = 'Salon Avize', bool locked = false}) =>
      (isOn: on, name: name, pending: false, offline: offline, canControl: true, locked: locked);

  ShutterVm sv({bool offline = false, String name = 'Salon Panjur', bool moving = false, int direction = 0}) => (
        pos: 40,
        moving: moving,
        direction: direction,
        target: null,
        name: name,
        isExt: false,
        pending: false,
        offline: offline,
        canControl: true,
        locked: false,
      );

  // ---------------------------------------------------------------------------------------------
  group('Bağlantı hapı metni: aynı ifade iki kez geçmez (r2_consoles)', () {
    testWidgets('pano çevrimdışı: üst çubuk hapı "Pano çevrimdışı • Bulut"', (tester) async {
      final h = await pumpReady(tester, const DashboardPage(), role: 'owner', size: const Size(800, 900));
      h.mqtt.emitPresence(false);
      await flush(tester);

      final badge = connectionBadgeOf(h.state);
      expect(badge.level, ConnectionLevel.offline);
      expect(badge.label, 'Pano çevrimdışı');
      expect(badge.detail, 'Bulut', reason: 'ayrıntı etiketi tekrarlamaz (eskiden "Bulut • pano çevrimdışı" idi)');
      final text = tester.widget<Text>(find.byKey(const Key('text_connection'))).data!;
      expect(text, 'Pano çevrimdışı • Bulut');
      expect('pano çevrimdışı'.allMatches(text.toLowerCase()), hasLength(1), reason: 'aynı ifade hapta tek kez');
    });

    testWidgets('telefonda (hap kabuğu yok) ekran okuyucu etiketi de tekrarsız', (tester) async {
      final h = await pumpReady(tester, const DashboardPage(), role: 'owner', size: const Size(360, 800));
      h.mqtt.emitPresence(false);
      await flush(tester);
      final label = tester.widget<Semantics>(find.byKey(const Key('text_connection'))).properties.label!;
      expect(label, 'Ev A, Pano çevrimdışı • Bulut');
    });
  });

  // ---------------------------------------------------------------------------------------------
  group('Durum şeridi: görünmez çocuk kilidi rozeti yuva tüketmez (r2_dashboard)', () {
    test('ChildLockChip.visibleFor: yalnız kilitli / uygulanan / panolar farklı durumda', () {
      ChildLockVm vm(ChildLockStatus status, {bool pending = false}) => (
            status: status,
            pending: pending,
            stale: false,
            updatedAt: null,
            canChange: true,
            awaitingDevices: false,
            offlineDeviceCount: 0,
          );
      expect(ChildLockChip.visibleFor(vm(ChildLockStatus.locked)), isTrue);
      expect(ChildLockChip.visibleFor(vm(ChildLockStatus.mixed)), isTrue);
      expect(ChildLockChip.visibleFor(vm(ChildLockStatus.unlocked, pending: true)), isTrue);
      expect(ChildLockChip.visibleFor(vm(ChildLockStatus.unlocked)), isFalse);
      expect(ChildLockChip.visibleFor(vm(ChildLockStatus.unknown)), isFalse);
    });

    testWidgets('rozet görünmezken ağaçta YOK; hap araları eşit 8 dp (eskiden 8 / 16 dp)', (tester) async {
      await pumpReady(tester, scaffolded(const DashboardStatusBar()), size: const Size(800, 400));
      expect(find.byType(ChildLockChip), findsNothing);
      final pills = find.byType(StatusPill);
      expect(pills, findsNWidgets(3));
      final rects = [for (var i = 0; i < 3; i++) tester.getRect(pills.at(i))];
      expect(rects[1].left - rects[0].right, 8);
      expect(rects[2].left - rects[1].right, 8);
    });

    testWidgets('rozet görününce dört hap yine 8 dp arayla dizilir', (tester) async {
      final h = await pumpReady(
        tester,
        scaffolded(const DashboardStatusBar()),
        size: const Size(1000, 400),
        endpoints: litEndpoints(),
      );
      h.mqtt.emitStateJson(stateJson(childLock: true));
      await flush(tester);
      expect(byKeyName('chip_child_lock'), findsOneWidget);
      final pills = find.byType(StatusPill);
      expect(pills, findsNWidgets(4));
      for (var i = 1; i < 4; i++) {
        expect(tester.getRect(pills.at(i)).left - tester.getRect(pills.at(i - 1)).right, 8, reason: 'hap $i');
      }
    });

    testWidgets('veri yokken tek hap kartın / içerik oluğunun sol kenarına oturur (8 dp içeride başlamaz)', (tester) async {
      await pumpReady(tester, scaffolded(const DashboardStatusBar()), endpoints: <EndpointModel>[]);
      expect(find.byType(StatusPill), findsOneWidget);
      expect(tester.getTopLeft(byKeyName('pill_system')).dx, 16, reason: 'scaffolded içerik oluğu 16 dp');
    });
  });

  // ---------------------------------------------------------------------------------------------
  group('Ev değiştirici oku başlığın hemen yanında (r2_dashboard / r2_cross)', () {
    void twoHomes(StateHarness h) => h.cloud.homes = <HomeModel>[testHome(), testHome(id: kHomeB, name: 'Yazlık')];

    testWidgets('telefon (360 dp): ok ev adının hemen sağında; değiştirici başlık bloğuna büzülür', (tester) async {
      await pumpReady(tester, const DashboardPage(), role: 'owner', size: const Size(360, 800), configure: twoHomes);
      final switcher = byKeyName('nav_home_switcher');
      final title = tester.getRect(find.descendant(of: switcher, matching: find.text('Ev A')));
      final arrow = tester.getRect(find.descendant(of: switcher, matching: find.byIcon(Icons.expand_more_rounded)));
      expect(arrow.left - title.right, inInclusiveRange(2, 10), reason: 'ok metne bitişik (eskiden ~110 dp uzaktaydı)');
      expect(tester.getSize(switcher).height, greaterThanOrEqualTo(48), reason: 'dokunma hedefi');
      // Dokunulabilir alan başlık + boşluk (4 dp) + ok (20 dp) kadardır: tüm başlık bölgesine yayılmaz (eskiden ok bölgenin
      // en sağındaydı ve değiştirici başlık bölgesinin tamamını kaplıyordu).
      expect(tester.getRect(switcher).right - title.right, closeTo(24, 1.0));
    });

    testWidgets('geniş çubuk (800 dp): ok bağlantı hapının hemen sağında', (tester) async {
      await pumpReady(tester, const DashboardPage(), role: 'owner', size: const Size(800, 900), configure: twoHomes);
      final switcher = byKeyName('nav_home_switcher');
      final pill = tester.getRect(find.descendant(of: switcher, matching: find.byType(GlassPill)));
      final arrow = tester.getRect(find.descendant(of: switcher, matching: find.byIcon(Icons.expand_more_rounded)));
      expect(arrow.left - pill.right, inInclusiveRange(2, 10));
      expect(tester.getRect(switcher).right - pill.right, closeTo(24, 1.0), reason: 'değiştirici hap + boşluk + ok kadar; bölgeye yayılmaz');
    });

    testWidgets('tüm başlık anlamlı tek düğüm: ad + durum etiketi ve "daireyi değiştir" ipucu; dokununca seçici açılır', (tester) async {
      final handle = tester.ensureSemantics();
      try {
        await pumpReady(tester, const DashboardPage(), role: 'owner', size: const Size(360, 800), configure: twoHomes);
        final node = tester.getSemantics(byKeyName('nav_home_switcher'));
        expect(node.label, contains('Ev A'));
        expect(node.hint, contains('Daireyi değiştirmek'));
        await tester.tap(byKeyName('nav_home_switcher'));
        await tester.pumpAndSettle();
        expect(byKeyName('sheet_home_switcher'), findsOneWidget);
      } finally {
        handle.dispose();
      }
    });
  });

  // ---------------------------------------------------------------------------------------------
  group('Üst çubuk: avatar rol ailesinde, menü ⋮ diskinin altında', () {
    testWidgets('avatar rengi profil diyaloğuyla AYNI kaynak: süper = violet, servis = cyan, ev sahibi = sky, aile bireyi = emerald',
        (tester) async {
      final cases = <({String global, String role, AccentFamily family})>[
        (global: 'super_user', role: 'owner', family: AppFamilies.violet),
        (global: 'service_user', role: 'owner', family: AppFamilies.cyan),
        (global: 'user', role: 'owner', family: AppFamilies.sky),
        (global: 'user', role: 'resident', family: AppFamilies.emerald),
      ];
      for (final c in cases) {
        await pumpReady(tester, const DashboardPage(), role: c.role, globalRole: c.global, size: const Size(800, 900));
        await flush(tester);
        final avatar = tester.widget<AvatarOrb>(find.descendant(of: byKeyName('nav_profile'), matching: find.byType(AvatarOrb)));
        expect(avatar.family, c.family, reason: '${c.global}/${c.role}');
      }
    });

    testWidgets('⋮ menüsü tetikleyicinin ALTINDA açılır; satır simgeleri özellik renginde mini orb', (tester) async {
      await pumpReady(tester, const DashboardPage(), role: 'owner', size: const Size(360, 800));
      await tester.tap(byKeyName('nav_overflow'));
      await tester.pumpAndSettle();
      final trigger = tester.getRect(byKeyName('nav_overflow'));
      final firstItem = tester.getRect(byKeyName('nav_family'));
      expect(firstItem.top, greaterThanOrEqualTo(trigger.bottom - 1), reason: 'menü tetikleyiciyi ve başlığı örtmez');
      for (final name in ['nav_family', 'nav_mode', 'nav_doctor', 'nav_refresh']) {
        expect(find.descendant(of: byKeyName(name), matching: find.byType(OrbIconBadge)), findsOneWidget, reason: name);
      }
    });
  });

  // ---------------------------------------------------------------------------------------------
  group('Izgara mevcut genişliği doldurur; tüm bölümler aynı sağ kenarda biter (r2_dashboard / r2_cross)', () {
    testWidgets('masaüstü (1280 dp): hero, senaryo satırı, panjur ve lamba kartlarının sağ kenarı aynı', (tester) async {
      await pumpReady(tester, const DashboardPage(), endpoints: litEndpoints(), size: const Size(1280, 1500));
      await flush(tester);
      final heroRight = tester.getRect(byKeyName('home_hero')).right;
      expect(heroRight, 1280 - (1280 - kDashboardMaxWidth) / 2, reason: 'içerik sütunu 1200 dp ortalı');
      final cards = find.byWidgetPredicate(
        (w) => w is SurfaceCard && ('${w.key}'.contains('card_relay_') || '${w.key}'.contains('card_shutter_')),
      );
      expect(cards, findsWidgets);
      var maxRight = 0.0;
      for (final element in cards.evaluate()) {
        final right = tester.getRect(find.byWidget(element.widget)).right;
        expect(right, lessThanOrEqualTo(heroRight + 0.01));
        if (right > maxRight) maxRight = right;
      }
      expect(maxRight, closeTo(heroRight, 0.6), reason: 'ızgara sağ kenarı hero / huzur bandı ile aynı');
      expect(tester.getRect(byKeyName('card_scenario_night')).right, lessThanOrEqualTo(heroRight + 0.01));
    });

    testWidgets('tek panjur kartı geniş kipte iki panel: orb eylemleri ve kaydırıcı adın SAĞINDA; dar kartta alt alta', (tester) async {
      Widget host(double width) => Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: width, child: ShutterCardView(pair: 1, vm: sv())),
            ),
          );
      await pumpReady(tester, host(900), size: const Size(1000, 800));
      final name = tester.getRect(find.text('Salon Panjur'));
      expect(tester.getRect(byKeyName('btn_shutter_up_1')).left, greaterThan(name.right), reason: 'iki panel');
      expect(tester.getRect(byKeyName('slider_shutter_1')).left, greaterThan(name.right));
      expect(tester.getRect(byKeyName('card_shutter_1')).width, 900);

      await pumpReady(tester, host(360), size: const Size(400, 900));
      final narrowName = tester.getRect(find.text('Salon Panjur'));
      expect(tester.getRect(byKeyName('btn_shutter_up_1')).top, greaterThan(narrowName.bottom), reason: 'dar kart: dikey düzen');
    });
  });

  // ---------------------------------------------------------------------------------------------
  group('Lamba kartı: AÇIK opak hap, ad kesilmez, "Tetikle" sütunu sabit (r2_dashboard / r2_cards_tone)', () {
    for (final theme in [ThemeMode.dark, ThemeMode.light]) {
      testWidgets('AÇIK durum metni OPAK amber hapta; hap zeminine karşı >= 4.5:1; KAPALI düz metin (${theme.name})', (tester) async {
        await pumpReady(
          tester,
          scaffolded(
            Column(children: [
              RelayCardView(relay: lamp, vm: rv(on: true)),
              RelayCardView(relay: lamp.copyWithId(2), vm: rv()),
            ]),
          ),
          themeMode: theme,
        );
        final pill = find.ancestor(of: find.text('AÇIK'), matching: find.byType(AppPill));
        expect(pill, findsOneWidget);
        final shell = find.descendant(of: pill, matching: find.byType(Container)).first;
        final gradient = (tester.widget<Container>(shell).decoration as BoxDecoration).gradient as LinearGradient;
        expect(gradient.colors.every((c) => c.a == 1.0), isTrue, reason: 'opak: orb halesi / bloom hapın altında kalmaz');
        final fg = tester.widget<Text>(find.text('AÇIK')).style!.color!;
        for (final bg in gradient.colors) {
          expect(wcagContrast(fg, bg), greaterThanOrEqualTo(4.5), reason: theme.name);
        }
        expect(find.ancestor(of: find.text('KAPALI'), matching: find.byType(AppPill)), findsNothing);
      });
    }

    testWidgets('çevrimdışı AÇIK (son bilinen) canlı gibi hap almaz: düz soluk metin', (tester) async {
      await pumpReady(tester, scaffolded(RelayCardView(relay: lamp, vm: rv(on: true, offline: true))));
      expect(find.text('AÇIK'), findsOneWidget);
      expect(find.ancestor(of: find.text('AÇIK'), matching: find.byType(AppPill)), findsNothing);
    });

    testWidgets('cardNameMaxLines: normal yazıda 3, büyük yazıda (>= 1.3x) 4 satır', (tester) async {
      var normal = 0;
      var large = 0;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.0)),
          child: Builder(
            builder: (context) {
              normal = cardNameMaxLines(context);
              return MediaQuery(
                data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
                child: Builder(
                  builder: (context) {
                    large = cardNameMaxLines(context);
                    return const SizedBox.shrink();
                  },
                ),
              );
            },
          ),
        ),
      );
      expect(normal, 3);
      expect(large, 4);
    });

    testWidgets('kart adı kesilmez: röle ve panjur adı normal yazıda en çok 3, 1.5x yazıda 4 satıra sarılır', (tester) async {
      const long = 'Teras Aydınlatma Uzun Adlı Şerit LED';
      for (final scale in [1.0, 1.5]) {
        await pumpReady(
          tester,
          scaffolded(
            Column(children: [
              RelayCardView(relay: lamp, vm: rv(on: true, name: long, locked: true)),
              ShutterCardView(pair: 1, vm: sv(name: long)),
            ]),
          ),
          size: const Size(360, 1400),
          textScale: scale,
        );
        final expected = scale >= 1.3 ? 4 : 3;
        final names = tester.widgetList<Text>(find.text(long)).toList();
        expect(names, hasLength(2));
        for (final t in names) {
          expect(t.maxLines, expected, reason: 'ölçek $scale');
        }
      }
    });

    testWidgets('"Tetikle" etiketi orb genişliğindeki sütunda (büyük yazıda sütun genişleyip metni kaydırmaz)', (tester) async {
      const impulse = RelayItem(id: 5, name: 'Bahçe Kapısı Açıcı', type: 3, state: false);
      await pumpReady(
        tester,
        scaffolded(
          Column(children: [
            RelayCardView(relay: lamp, vm: rv()),
            RelayCardView(relay: impulse, vm: rv(name: 'Bahçe Kapısı Açıcı')),
          ]),
        ),
        size: const Size(360, 800),
        textScale: 1.5,
      );
      final lampName = tester.getTopLeft(find.text('Salon Avize')).dx;
      final impulseName = tester.getTopLeft(find.text('Bahçe Kapısı Açıcı')).dx;
      expect(impulseName, closeTo(lampName, 0.5), reason: 'metin sütunları aynı x\'ten başlar');
    });
  });

  // ---------------------------------------------------------------------------------------------
  group('Panjur kaydırıcısı: çevrimdışı aktiften SÖNÜK, açık tema başparmağı soluk değil, etiketler iz uçlarında', () {
    for (final theme in [ThemeMode.light, ThemeMode.dark]) {
      testWidgets('çevrimdışı panjurun izi ve başparmağı TEK pasif iz belirteciyle (getInactiveTrack, >= 3:1); canlı iz aile rengi (${theme.name})',
          (tester) async {
        await pumpReady(
          tester,
          scaffolded(
            Column(children: [
              ShutterCardView(pair: 1, vm: sv()),
              ShutterCardView(pair: 2, vm: sv(offline: true, name: 'Yatak Odası Panjur')),
              ShutterCardView(pair: 3, vm: sv(moving: true, direction: 1, name: 'Mutfak Panjur')),
            ]),
          ),
          size: const Size(400, 1800),
          themeMode: theme,
        );
        final context = tester.element(byKeyName('slider_shutter_2'));
        final live = SliderTheme.of(tester.element(byKeyName('slider_shutter_1')));
        final offline = SliderTheme.of(context);
        final opening = SliderTheme.of(tester.element(byKeyName('slider_shutter_3')));
        final inactive = AppTheme.getInactiveTrack(context);
        expect(offline.activeTrackColor, inactive, reason: 'çevrimdışı iz: pasif iz belirteci (iki temada aynı kural)');
        expect(offline.thumbColor, inactive, reason: 'çevrimdışı başparmak: aynı belirteç');
        expect(wcagContrast(inactive, SurfaceTokens.of(theme == ThemeMode.dark ? Brightness.dark : Brightness.light).cardTop),
            greaterThanOrEqualTo(3.0));
        // Canlı kart: iz hareket yönü ailesinin ana tonu, başparmak açık ton (açık temada tema başparmağı koyu halka çizer).
        expect(live.activeTrackColor, AppFamilies.sky.base);
        expect(live.thumbColor, AppFamilies.sky.light);
        expect(opening.activeTrackColor, AppFamilies.emerald.base);
        expect(opening.thumbColor, AppFamilies.emerald.light);
        if (theme == ThemeMode.light) {
          // Eskiden çevrimdışı iz koyu slate #4B5B70 idi (kart karşısı ≈ 7:1): canlı mavi izden (≈ 3.7:1) baskındı. Pasif iz
          // belirteci nötr orta slate'tir (≈ 3.3:1): etkin (aile renkli) izden daha sönük/nötr.
          expect(wcagContrast(offline.activeTrackColor!, Colors.white), lessThan(4.0));
          expect(offline.activeTrackColor, isNot(AppTheme.textMutedLight));
        }
      });
    }

    testWidgets('"Kapalı / Açık" etiketleri kaydırıcı izinin uçlarıyla hizalı (iz 24 dp içeriden başlar)', (tester) async {
      await pumpReady(tester, scaffolded(ShutterCardView(pair: 1, vm: sv())), size: const Size(400, 800));
      final slider = tester.getRect(byKeyName('slider_shutter_1'));
      final closed = tester.getRect(find.text('Kapalı'));
      final open = tester.getRect(find.text('Açık'));
      // Slider widget'ı iz payını (24 dp) kendi içinde taşır: etiketler iz uçlarıyla (slider kutusu ± 24 dp) hizalanır.
      expect(closed.left, closeTo(slider.left + 24, 1.5));
      expect(open.right, closeTo(slider.right - 24, 1.5));
    });
  });

  // ---------------------------------------------------------------------------------------------
  group('Konsollar: bölüm başlığı SectionHeader; çok dar ekranda sayaçlar tek sütun (r2_consoles)', () {
    testWidgets('SectionHeader rozetsiz ve eylemli kullanılabilir (badge / action ikisi birden verilmez)', (tester) async {
      await pumpReady(
        tester,
        scaffolded(
          Column(children: [
            const SectionHeader(icon: Icons.bolt_rounded, title: 'Yalnız başlık'),
            const SectionHeader(icon: Icons.bolt_rounded, title: 'Rozetli', badge: '3 Motor'),
            SectionHeader(icon: Icons.bolt_rounded, title: 'Eylemli', action: TextButton(onPressed: () {}, child: const Text('Aç'))),
          ]),
        ),
        size: const Size(800, 400),
      );
      expect(find.text('Yalnız başlık'), findsOneWidget);
      expect(find.text('3 Motor'), findsOneWidget);
      expect(find.text('Aç'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('sayaç rozetleri (AppPill WordSafeLabel): 360 dp + 1.5x iki sütun korunur, rozetler eşit yükseklikte ve tek satır', (tester) async {
      await pumpReady(
        tester,
        const DashboardPage(),
        role: 'owner',
        globalRole: 'super_user',
        size: const Size(360, 2400),
        textScale: 1.5,
      );
      await flush(tester);
      expect(
        tester.getTopLeft(byKeyName('card_metric_devices')).dy,
        tester.getTopLeft(byKeyName('card_metric_service_managers')).dy,
        reason: '360 dp + 1.5x: iki sütun (yan yana) davranışı değişmedi',
      );
      // 'ENVANTER' / 'YÖNETİCİ' rozetleri sözcük ortasından bölünmez: ikisi de TEK satır, aynı yükseklik. (Gerçek yazı tipiyle
      // 320 dp + 1.5x görünümü golden'da: super_console_small_*_1.5.png.)
      final envanter = tester.getSize(find.ancestor(of: find.text('ENVANTER'), matching: find.byType(GlassPill)).first);
      final yonetici = tester.getSize(find.ancestor(of: find.text('YÖNETİCİ'), matching: find.byType(GlassPill)).first);
      expect(envanter.height, yonetici.height, reason: 'rozet yükseklikleri eşit (komşu rozetle)');
      expect(envanter.height, lessThan(18 * 1.5 * 1.2 + 16), reason: 'tek satır (iki satırlı kapsül değil)');
    });

    testWidgets('çekmece tema satırı özellik haritasının dışında NÖTR (slate) ve gezinme oku (›) yok', (tester) async {
      Future<void> pumpDrawer(String role) async {
        await pumpReady(
          tester,
          const Scaffold(drawer: SuperUserDrawer(), body: SizedBox()),
          role: 'owner',
          globalRole: role,
        );
        tester.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
        await tester.pumpAndSettle();
      }

      for (final role in ['super_user', 'service_user']) {
        await pumpDrawer(role);
        final theme = byKeyName('nav_drawer_theme');
        expect(tester.widget<OrbIconBadge>(find.descendant(of: theme, matching: find.byType(OrbIconBadge))).family, AppFamilies.slate,
            reason: role);
        expect(find.descendant(of: theme, matching: find.byIcon(Icons.chevron_right_rounded)), findsNothing, reason: role);
        expect(find.descendant(of: theme, matching: find.byIcon(Icons.swap_horiz_rounded)), findsOneWidget, reason: role);
        // Gezinme satırları okunu korur.
        expect(find.descendant(of: byKeyName('nav_drawer_console'), matching: find.byIcon(Icons.chevron_right_rounded)), findsOneWidget);
      }
    });
  });

  // ---------------------------------------------------------------------------------------------
  group('Pano durum ekranları: daire seçici orb satırları, süresi dolmuş = amber, senaryo / başlık renk dili', () {
    testWidgets('daire seçici satırları parlak mini orb: normal = sky ev simgesi, süresi dolmuş = amber', (tester) async {
      final h = (await tester.runAsync(
        () => e1Ready(
          home: guestHome(hours: 1, name: 'Yazlık'),
          configure: (h) => h.cloud.homes = <HomeModel>[guestHome(hours: 1, name: 'Yazlık'), testHome(id: kHomeB, name: 'Ev B')],
        ),
      ))!;
      addTearDown(h.dispose);
      h.clock.advance(const Duration(hours: 2));
      await pumpPage(tester, h.state, scaffolded(const HomePickerList()), size: const Size(800, 900));

      OrbIconBadge orbOf(String homeId) =>
          tester.widget<OrbIconBadge>(find.descendant(of: byKeyName('card_home_$homeId'), matching: find.byType(OrbIconBadge)));
      expect(orbOf(kHomeA).family, AppFamilies.amber, reason: 'süresi dolmuş: erişim/kilit = amber (rose tehlikedir)');
      expect(orbOf(kHomeA).icon, Icons.timer_off_rounded);
      expect(orbOf(kHomeB).family, AppFamilies.sky);
      expect(orbOf(kHomeB).icon, Icons.home_rounded);
      expect(find.byIcon(Icons.home_outlined), findsNothing, reason: 'çıplak Material ev simgesi kalmadı');
    });

    testWidgets('erişimi dolmuş misafir kartı AMBER (üst çubuk rozetiyle aynı aile) ve lg orb', (tester) async {
      final h = (await tester.runAsync(() => e1Ready(home: guestHome(hours: 1, name: 'Yazlık'))))!;
      addTearDown(h.dispose);
      h.clock.advance(const Duration(hours: 2));
      await pumpPage(tester, h.state, const Scaffold(body: ApartmentDashboard()), size: const Size(800, 900));
      final card = tester.widget<StateCard>(byKeyName('view_guest_expired'));
      expect(card.accent, AppFamilies.amber.base);
      final orb = tester.widget<OrbIconBadge>(find.descendant(of: byKeyName('view_guest_expired'), matching: find.byType(OrbIconBadge)));
      expect(orb.family, AppFamilies.amber);
      expect(orb.size, OrbSize.lg, reason: 'xl yalnız karşılama hero\'larında');
      expect(connectionBadgeOf(h.state).family, AppFamilies.amber, reason: 'rozet de amber: tek aile');
    });

    test('hazır senaryoların orb aileleri panonun anlam haritasından türer ve benzersizdir', () {
      final byId = {for (final s in kQuickScenarios) s.id: s.family};
      expect(byId['lights_off'], AppFamilies.amber, reason: 'lamba = amber');
      expect(byId['morning'], AppFamilies.emerald, reason: 'panjur AÇ = emerald');
      expect(byId['leaving'], AppFamilies.sky, reason: 'panjur KAPAT (+ ışıklar) = sky');
      expect(byId['night'], AppFamilies.violet, reason: 'gece = violet');
      expect(byId['shutters_stop'], AppFamilies.rose, reason: 'Durdur = rose (panjur kartındaki ■ ile aynı)');
      expect(byId.values.toSet(), hasLength(kQuickScenarios.length), reason: 'beş aile benzersiz');
    });

    testWidgets('bölüm başlığı orb aileleri: panjur = sky, aydınlatma = amber', (tester) async {
      await pumpReady(tester, scaffolded(const DeviceSections()), size: const Size(800, 1600));
      AccentFamily familyOf(String title) =>
          tester.widget<SectionHeader>(find.ancestor(of: find.text(title), matching: find.byType(SectionHeader))).family;
      expect(familyOf('Panjurlar'), AppFamilies.sky);
      expect(familyOf('Aydınlatma & Çıkışlar'), AppFamilies.amber);
    });
  });

  // ---------------------------------------------------------------------------------------------
  group('Profil diyaloğu: tema çipleri AppChip diliyle (tür ChoiceChip korunur), orb hesap rozetleri', () {
    for (final theme in [ThemeMode.dark, ThemeMode.light]) {
      testWidgets('seçili çip tonlu OPAK dolgu + onay işareti; seçili olmayan >= 3:1 kenar (${theme.name})', (tester) async {
        final env = e2Env(role: 'owner');
        await env.state.setThemeMode(ThemeMode.system);
        await openFromHost<void>(tester, env.state, size: const Size(412, 1800), themeMode: theme, (c) => UserProfileDialog.show(c));
        final surface = AppTheme.getSurfaceColor(tester.element(find.byType(UserProfileDialog)));

        final selected = tester.widget<ChoiceChip>(byKeyName('theme_system'));
        expect(selected.selected, isTrue);
        expect(selected.selectedColor, isNot(AppTheme.primaryBlue), reason: 'düz #2563EB seçili çip kalmadı');
        expect(selected.selectedColor!.a, 1.0, reason: 'opak tonlu dolgu');
        expect(selected.showCheckmark, isFalse, reason: 'onay işareti etiketin içinde (genişlik oynamaz)');
        expect(find.descendant(of: byKeyName('theme_system'), matching: find.byIcon(Icons.check_rounded)), findsOneWidget);
        expect(find.descendant(of: byKeyName('theme_system'), matching: find.byIcon(Icons.brightness_auto_rounded)), findsNothing);
        final selectedLabel = tester.widget<Text>(find.descendant(of: byKeyName('theme_system'), matching: find.text('Sistem')));
        expect(wcagContrast(selectedLabel.style!.color!, selected.selectedColor!), greaterThanOrEqualTo(4.5));
        expect(selectedLabel.style!.fontWeight, FontWeight.w800);

        for (final key in ['theme_light', 'theme_dark']) {
          final chip = tester.widget<ChoiceChip>(byKeyName(key));
          expect(chip.selected, isFalse);
          expect(wcagContrast(chip.side!.color, surface), greaterThanOrEqualTo(3.0), reason: '$key kenarı (eskiden 1.4:1)');
          expect(chip.side!.width, selected.side!.width, reason: 'kenar kalınlığı seçimle değişmez');
          expect(find.descendant(of: byKeyName(key), matching: find.byIcon(Icons.check_rounded)), findsNothing, reason: key);
        }
      });
    }

    for (final width in [360.0, 800.0]) {
      testWidgets('üç tema çipi EŞİT genişlikte tek sırada (${width.toInt()} dp)', (tester) async {
        final env = e2Env(role: 'owner');
        await openFromHost<void>(tester, env.state, size: Size(width, 1800), (c) => UserProfileDialog.show(c));
        final rects = [for (final k in ['theme_system', 'theme_light', 'theme_dark']) tester.getRect(byKeyName(k))];
        expect(rects.map((r) => r.top.round()).toSet(), hasLength(1), reason: 'tek sıra');
        expect(rects[1].width, closeTo(rects[0].width, 0.01));
        expect(rects[2].width, closeTo(rects[0].width, 0.01));
        // Dolgu etiketle birlikte: çipler arası 8 dp'ye yakın boşluk, sağ çip içerik genişliğini aşmaz.
        expect(rects[1].left - rects[0].right, inInclusiveRange(6, 14));
        expect(rects[2].left - rects[1].right, inInclusiveRange(6, 14));
      });
    }

    testWidgets('"Oturumu Kapat" kenarı açık temada >= 3:1 (eskiden rose@.60 ≈ 2.3:1)', (tester) async {
      final env = e2Env(role: 'owner');
      await openFromHost<void>(tester, env.state, size: const Size(412, 1800), themeMode: ThemeMode.light, (c) => UserProfileDialog.show(c));
      final side = tester.widget<OutlinedButton>(byKeyName('btn_logout')).style!.side!.resolve(<WidgetState>{})!;
      expect(wcagContrast(side.color, Colors.white), greaterThanOrEqualTo(3.0));
      final context = tester.element(byKeyName('btn_logout'));
      expect(side.color, AppTheme.outlinedBorder(context, AppFamilies.rose), reason: 'tüm çerçeveli düğmelerle aynı tek ton kuralı');
      expect(side.width, 1.5);
    });

    testWidgets('birincil düğme etiketi iki satıra sarılınca simge etikete bitişik kalır (longestLine)', (tester) async {
      final env = e2Env(role: 'owner');
      await openFromHost<void>(tester, env.state, size: const Size(360, 1800), (c) => UserProfileDialog.show(c));
      final text = tester.widget<Text>(find.descendant(of: byKeyName('btn_open_family'), matching: find.byType(Text)).first);
      expect(text.textWidthBasis, TextWidthBasis.longestLine);
      expect(text.maxLines, 2, reason: 'satır sınırı değişmedi');
    });
  });
}

extension on RelayItem {
  RelayItem copyWithId(int newId) => RelayItem(id: newId, name: name, type: type, state: state);
}
