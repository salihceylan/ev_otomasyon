import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/ui/pages/device_inventory_page.dart';
import 'package:ev_otomasyon/ui/pages/service_mode_page.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/panel/service_glass.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_fields.dart';
import 'package:ev_otomasyon/ui/theme/app_theme.dart';
import 'package:ev_otomasyon/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'f_support.dart';
import 'f_widget_support.dart';

/// WP-FX-D (2. tur eleştirmen bulguları, servis + sihirbaz): ortak servis bileşenlerinin düzeltmeleri.
///
///  * `ServiceActionGrid`: telefonda tek sütun (3 satırlık "yumurta" hap yok), geniş yerde iki sütun; son satırdaki tek düğme
///    tam genişlik.
///  * `ServiceStepDots`: görünür "n/m" metni + bekleyen nokta ≥ 3:1.
///  * `ServiceProgressRing`: iz ≥ 3:1.
///  * `SetupTextField`: mono kodlarda yazı ölçeği sınırı, tek satırlı ipucu, çok satırlı alanda satır içi ön simge.
Widget _host(
  Widget child, {
  double width = 296,
  double scale = 1.0,
  Brightness brightness = Brightness.dark,
}) {
  return MaterialApp(
    theme: ThemeData(brightness: brightness),
    builder: (context, c) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
      child: c!,
    ),
    home: Scaffold(
      body: SingleChildScrollView(
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: width, child: child),
        ),
      ),
    ),
  );
}

Widget _button(String key, String label) =>
    OutlinedButton(key: Key(key), onPressed: () {}, child: Text(label, textAlign: TextAlign.center));

void main() {
  group('ServiceActionGrid', () {
    testWidgets('360 dp telefonda ızgara ≈ 296 dp: iki düğme alt alta TAM genişlikte (yarım genişlikte 3 satıra sarmaz)', (tester) async {
      await tester.pumpWidget(
        _host(
          ServiceActionGrid(
            children: [_button('a', 'Bağlantıyı yeniden kur'), _button('b', 'Daveti yeniden gönder')],
          ),
        ),
      );
      final a = tester.getRect(find.byKey(const Key('a')));
      final b = tester.getRect(find.byKey(const Key('b')));
      expect(a.width, closeTo(296, 0.5), reason: 'tek sütun: tam genişlik');
      expect(b.width, closeTo(296, 0.5));
      expect(b.top, greaterThanOrEqualTo(a.bottom), reason: 'alt alta');
    });

    testWidgets('geniş yerde (≥ 2 x 156 + 8 dp) iki eşit sütun; etiket en çok 2 satır', (tester) async {
      await tester.pumpWidget(
        _host(
          width: 360,
          ServiceActionGrid(
            children: [_button('a', 'Bağlantıyı yeniden kur'), _button('b', 'Testleri yap')],
          ),
        ),
      );
      final a = tester.getRect(find.byKey(const Key('a')));
      final b = tester.getRect(find.byKey(const Key('b')));
      expect(a.top, b.top, reason: 'yan yana');
      expect(b.left, greaterThan(a.right));
      expect(a.width, closeTo(b.width, 0.5), reason: 'eşit genişlik');
      expect(a.height, b.height, reason: 'satırdaki düğmeler eşit yükseklikte');
    });

    testWidgets('son satırda tek düğme kalırsa tam genişliğe yayılır (yarım genişlikte sola yaslı tek hap YOK)', (tester) async {
      await tester.pumpWidget(
        _host(
          width: 360,
          ServiceActionGrid(
            children: [_button('a', 'Düzenle'), _button('b', 'Bağlantı gönder'), _button('c', 'Dondur')],
          ),
        ),
      );
      final a = tester.getRect(find.byKey(const Key('a')));
      final c = tester.getRect(find.byKey(const Key('c')));
      expect(a.width, lessThan(c.width), reason: 'üçüncü düğme satırı doldurur');
      expect(c.width, closeTo(360, 0.5));
      expect(c.top, greaterThanOrEqualTo(a.bottom));
    });

    testWidgets('büyük yazıda (1.5x) geniş yerde bile tek sütun', (tester) async {
      await tester.pumpWidget(
        _host(
          width: 400,
          scale: 1.5,
          ServiceActionGrid(
            children: [_button('a', 'Düzenle'), _button('b', 'Dondur')],
          ),
        ),
      );
      final a = tester.getRect(find.byKey(const Key('a')));
      final b = tester.getRect(find.byKey(const Key('b')));
      expect(a.left, b.left);
      expect(b.top, greaterThanOrEqualTo(a.bottom));
      expect(tester.takeException(), isNull);
    });
  });

  group('ServiceBalancedLabel (yetim sözcüksüz etiket)', () {
    // Ahem yazı tipinde her harf `fontSize` genişliğindedir (10 px): "aaaaaaa bbbbbbb c" 160 px'e SIĞAN ilk satırı 15 harf (150 px)
    // alır ve "c" tek başına ikinci satırda kalır (yetim). Dengeli genişlik ("aaaaaaa" / "bbbbbbb c") ≈ 94 px'tir.
    const style = TextStyle(fontSize: 10);
    const text = 'aaaaaaa bbbbbbb c';

    testWidgets('yetim son sözcük oluşacaksa blok en dar eşit-satır genişliğine daralır; metin DEĞİŞMEZ', (tester) async {
      await tester.pumpWidget(_host(width: 160, const ServiceBalancedLabel(text, style: style, textKey: Key('t'))));
      expect(find.text(text), findsOneWidget, reason: 'aynı Text (find.text/ekran okuyucu etkilenmez)');
      final width = tester.getSize(find.byKey(const Key('t'))).width;
      expect(width, lessThan(110), reason: 'greedy sarma 150 px kaplayıp "c"yi yetim bırakırdı; dengeli ≈ 94 px');
      expect(width, greaterThanOrEqualTo(90), reason: 'en uzun satır ("bbbbbbb c") sığmalı');
    });

    testWidgets('tek satıra sığan metin normal Text gibidir (daraltma yok)', (tester) async {
      // Düğmedeki gibi `Row(min) > Flexible`: gevşek kısıt (sıkı üst kısıtta Text tam genişliği alırdı).
      await tester.pumpWidget(
        _host(
          width: 300,
          const Row(
            mainAxisSize: MainAxisSize.min,
            children: [Flexible(child: ServiceBalancedLabel(text, style: style, textKey: Key('t'), centered: true))],
          ),
        ),
      );
      expect(tester.getSize(find.byKey(const Key('t'))).width, closeTo(170, 6), reason: '17 harf x 10 px (tek satır)');
      expect(tester.getSize(find.byKey(const Key('t'))).height, lessThan(15), reason: 'tek satır');
    });

    testWidgets('düğme içinde (Flexible) simgeyle birlikte ortalanır ve etiket kırpılmaz', (tester) async {
      await tester.pumpWidget(
        _host(
          width: 200,
          OutlinedButton(
            key: const Key('b'),
            onPressed: () {},
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [Icon(Icons.wifi_rounded, size: 20), SizedBox(width: 10), Flexible(child: ServiceBalancedLabel('Wi-Fi Kurulum ve Kurtarma Sihirbazı', centered: true))],
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Wi-Fi Kurulum ve Kurtarma Sihirbazı'), findsOneWidget);
    });
  });

  group('ServiceEmptyState', () {
    testWidgets('kart içeriğe BÜZÜŞMEZ: komşu kartlarla aynı (tam) genişlikte (Column(crossAxisAlignment: start) içinde bile)', (
      tester,
    ) async {
      // Eskiden "Yarım kalan kurulum yok" kartı içeriğe göre daralıp komşu kartlardan ≈ 46 dp dar kalıyordu.
      await tester.pumpWidget(
        _host(
          width: 300,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              ServiceCard(
                key: Key('empty'),
                child: ServiceEmptyState(icon: Icons.assignment_turned_in_rounded, title: 'Yarım kalan kurulum yok', message: 'Kısa.'),
              ),
              ServiceCard(key: Key('neighbour'), child: SizedBox(width: double.infinity, child: Text('Komşu kart'))),
            ],
          ),
        ),
      );
      expect(tester.getSize(find.byKey(const Key('empty'))).width, 300);
      expect(tester.getSize(find.byKey(const Key('neighbour'))).width, 300, reason: 'komşu kart zaten tam genişlikte olmalı');
    });
  });

  group('tek gradyan birincil eylem: sayfa düzeyinde', () {
    int enabledGradientButtons(WidgetTester tester) =>
        tester.widgetList<ElevatedButton>(find.byType(ElevatedButton)).where((b) => b.onPressed != null).length;

    testWidgets('servis paneli (personel): tek gradyan "Yeni Kurulum Başlat"; "Acil Sıfırla", "Çıkış Yap" çerçeveli', (tester) async {
      final env = await serviceHarness(role: 'staff', flush: () async {});
      addTearDown(env.dispose);
      await pumpPage(
        tester,
        env,
        ServiceModePage(store: env.store, deviceApiFactory: env.deviceFactory, scanner: fakeScanner(null)),
        size: const Size(900, 3200),
      );
      await settle(tester, frames: 20);
      expect(find.byKey(const Key('btn_emergency_reset')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('btn_emergency_reset')), matching: find.byType(OutlinedButton)), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('btn_new_setup')), matching: find.byType(ElevatedButton)), findsOneWidget);
      expect(enabledGradientButtons(tester), 1, reason: 'sayfanın TEK gradyan birincil eylemi: Yeni Kurulum Başlat');
    });

    testWidgets('cihaz envanteri: hiçbir kartta gradyan birincil yok ("Karekod Gör" çerçeveli cyan)', (tester) async {
      final env = await serviceHarness(role: 'super', flush: () async {});
      addTearDown(env.dispose);
      env.cloud.inventory = <InventoryDeviceModel>[
        inventoryDevice(uid: 'AHBU-S3-A1B2C3', status: 'IN_STOCK', serial: 1),
        inventoryDevice(uid: 'AHBU-S3-D4E5F6', status: 'CLAIMED', serial: 2, claimedHome: 'Daire 5'),
        inventoryDevice(uid: 'AHBU-S3-0A0B0C', status: 'SUSPENDED', serial: 3),
      ];
      await pumpPage(tester, env, const DeviceInventoryPage(), size: const Size(900, 3000));
      await settle(tester, frames: 20);
      for (final uid in const ['AHBU-S3-A1B2C3', 'AHBU-S3-D4E5F6', 'AHBU-S3-0A0B0C']) {
        expect(tester.widget(find.byKey(Key('btn_qr_$uid'))), isA<OutlinedButton>(), reason: '$uid: Karekod Gör çerçeveli');
      }
      expect(enabledGradientButtons(tester), 0, reason: '3 özdeş gradyan CTA yerine sayfada gradyan birincil eylem yok');
    });
  });

  group('ServiceStepDots', () {
    testWidgets('görünür "n/m" metni var ve ekran okuyucuya yalnız tek anlamsal etiket verilir', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(const ServiceStepDots(current: 2, total: 3)));
      expect(find.text('2/3'), findsOneWidget);
      expect(find.bySemanticsLabel('Adım 2 / 3'), findsOneWidget);
      expect(find.bySemanticsLabel('2/3'), findsNothing, reason: 'görünür metin anlamdan hariç (çift okunmaz)');
      handle.dispose();
    });

    testWidgets('showCount: false görünür metni gizler', (tester) async {
      await tester.pumpWidget(_host(const ServiceStepDots(current: 1, total: 3, showCount: false)));
      expect(find.byKey(const Key('step_dots_count')), findsNothing);
    });

    for (final brightness in Brightness.values) {
      testWidgets('bekleyen nokta kart üstünde ≥ 3:1 (${brightness.name})', (tester) async {
        await tester.pumpWidget(_host(const ServiceStepDots(current: 1, total: 3), brightness: brightness));
        final dots = tester
            .widgetList<AnimatedContainer>(find.descendant(of: find.byType(ServiceStepDots), matching: find.byType(AnimatedContainer)))
            .map((w) => (w.decoration! as BoxDecoration).color!)
            .toList();
        expect(dots, hasLength(3));
        final tokens = SurfaceTokens.of(brightness);
        final passive = dots.last;
        expect(wcagContrast(passive, tokens.cardTop), greaterThanOrEqualTo(3.0), reason: 'kart üst ucu');
        expect(wcagContrast(passive, tokens.cardBottom), greaterThanOrEqualTo(3.0), reason: 'kart alt ucu');
        expect(dots.first, isNot(passive), reason: 'dolu ve bekleyen nokta ayrışır');
      });
    }
  });

  group('ServiceProgressRing', () {
    for (final brightness in Brightness.values) {
      testWidgets('iz alan kenarı belirteciyle çizilir (≥ 3:1) (${brightness.name})', (tester) async {
        const arc = Color(0xFF2563EB);
        await tester.pumpWidget(_host(const ServiceProgressRing(value: 0.4, color: arc), brightness: brightness));
        final ring = tester.renderObject(
          find.descendant(of: find.byType(ServiceProgressRing), matching: find.byType(CustomPaint)).first,
        );
        final track = AppTheme.inactiveTrackOn(brightness);
        expect(ring, paints..arc(color: track)..arc(color: arc), reason: 'önce iz, sonra dolu yay');
        final tokens = SurfaceTokens.of(brightness);
        expect(wcagContrast(track, tokens.cardTop), greaterThanOrEqualTo(3.0));
        expect(wcagContrast(track, tokens.cardBottom), greaterThanOrEqualTo(3.0));
      });
    }
  });

  group('SetupTextField', () {
    Future<TextField> pumpField(
      WidgetTester tester, {
      required bool monospace,
      int maxLines = 1,
      double scale = 1.0,
      IconData? prefixIcon = Icons.memory_rounded,
    }) async {
      final controller = TextEditingController(text: 'AHBU-S3-A1B2C3');
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _host(
          scale: scale,
          SetupTextField(
            key: const Key('f'),
            controller: controller,
            label: 'Cihaz kimliği',
            hint: 'AHBU-...',
            prefixIcon: prefixIcon,
            monospace: monospace,
            maxLines: maxLines,
          ),
        ),
      );
      return tester.widget<TextField>(find.byType(TextField));
    }

    testWidgets('mono kodda (UID/PIN) etkin yazı boyutu en çok 15 x 1.25: 1.5x ölçekte "AHBU" ilk harfi kesilmez', (tester) async {
      final big = await pumpField(tester, monospace: true, scale: 1.5);
      expect(big.style!.fontSize! * 1.5, lessThanOrEqualTo(15 * SetupTextField.monoMaxScale + 0.01));
      expect(big.style!.fontFamily, 'monospace');
      final big2 = await pumpField(tester, monospace: true, scale: 2.0);
      expect(big2.style!.fontSize! * 2.0, lessThanOrEqualTo(15 * SetupTextField.monoMaxScale + 0.01));
      final normal = await pumpField(tester, monospace: true, scale: 1.0);
      expect(normal.style!.fontSize, 15, reason: '1.0 ölçekte değişmez');
      final mid = await pumpField(tester, monospace: true, scale: 1.15);
      expect(mid.style!.fontSize, 15, reason: '≤ 1.25 ölçekte değişmez');
    });

    testWidgets('mono OLMAYAN alan 1.5x ölçekte normal ölçeklenir (sınır yalnız makine kodlarında)', (tester) async {
      final field = await pumpField(tester, monospace: false, scale: 1.5);
      expect(field.style!.fontSize, 15);
    });

    testWidgets('tek satırlı alanda ipucu TEK satır; çok satırlı alanda 2 satır (dolu alan şişmez)', (tester) async {
      final single = await pumpField(tester, monospace: false);
      expect(single.decoration!.hintMaxLines, 1);
      final multi = await pumpField(tester, monospace: false, maxLines: 3);
      expect(multi.decoration!.hintMaxLines, 2);
    });

    testWidgets('çok satırlı alanda ön simge ilk satırın hizasında (satır içi prefix); tek satırlıda prefixIcon', (tester) async {
      final single = await pumpField(tester, monospace: false);
      expect(single.decoration!.prefixIcon, isNotNull);
      expect(single.decoration!.prefix, isNull);
      final multi = await pumpField(tester, monospace: false, maxLines: 3);
      expect(multi.decoration!.prefixIcon, isNull, reason: 'prefixIcon alanın dikey ortasına otururdu');
      expect(multi.decoration!.prefix, isNotNull);
      expect(find.byIcon(Icons.memory_rounded), findsOneWidget, reason: 'simge yine görünür');
      expect(multi.decoration!.alignLabelWithHint, isFalse, reason: 'etiket kenar çentiğinde (tek satırlı alanlarla aynı hiza)');
    });
  });
}
