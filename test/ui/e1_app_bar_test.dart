import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/ui/pages/dashboard_page.dart';
import 'package:ev_otomasyon/ui/theme/tokens.dart';
import 'package:ev_otomasyon/ui/widgets/orb/orb.dart';
import 'package:ev_otomasyon/ui/widgets/user_profile_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';
import 'e1_helpers.dart';

/// Pano üst çubuğu başlık bloğu (WP-F3): çubuk **kendi genişliğine göre uyum sağlar** (cihaz genişliğine değil):
/// yer yoksa bağlantı hapı KABUĞU çizilmez (boş kapsül yok), marka halkası düşer, başlık iki satıra sarılır; disk
/// kenarları 16 dp içerik oluğuna oturur; hiçbir ölçek/genişlikte taşma yoktur.
///
/// Not: `flutter test`'te yazı tipi Ahem'dir (her harf 1 em genişliğinde): düzen KARARLARI (hangi kipin seçildiği)
/// doğrulanır; gerçek yazı tipiyle okunurluk `test/visual/consoles` galerisindedir.
void main() {
  Finder inBar(Finder f) => find.descendant(of: find.byType(AppBar), matching: f);

  bool exceeded(WidgetTester tester, Finder f) => tester.renderObject<RenderParagraph>(f).didExceedMaxLines;

  group('apartman çubuğu', () {
    testWidgets('geniş çubukta (800 dp) bağlantı hapı tam metinle çizilir ve başlık tek satırdır', (tester) async {
      await pumpReady(tester, const DashboardPage(), role: 'owner', size: const Size(800, 900));

      expect(inBar(find.byType(GlassPill)), findsOneWidget);
      final text = find.byKey(const Key('text_connection'));
      expect(tester.widget<Text>(text).data, 'Sistem Hazır • Bulut');
      expect(exceeded(tester, text), isFalse, reason: 'hap metni kesilmez');
      expect(tester.widget<Text>(inBar(find.text('Ev A'))).maxLines, 1);
      expect(inBar(find.byType(GlowDot)), findsOneWidget, reason: 'hapın başındaki canlı nokta');
    });

    testWidgets('telefonda (360 dp) hap KABUĞU çizilmez: durum göstergesi + tam metin ekran okuyucu etiketi (boş kapsül yok)',
        (tester) async {
      await pumpReady(tester, const DashboardPage(), role: 'owner', size: const Size(360, 800));

      expect(inBar(find.byType(GlassPill)), findsNothing, reason: 'dar çubukta boş kapsül bırakılmaz');
      final mark = tester.widget<Semantics>(find.byKey(const Key('text_connection')));
      // Ekran okuyucu bloğu tek düğümde "ev adı, durum" sırasıyla okur; durum rengin dışında metinle de ulaşılır.
      expect(mark.properties.label, 'Ev A, Sistem Hazır • Bulut');
      expect(inBar(find.byType(GlowDot)), findsOneWidget);
      // `text_connection` her an en çok BİR tane: hem hap hem gösterge birlikte olmaz.
      expect(find.byKey(const Key('text_connection')), findsOneWidget);
      // Başlık iki satıra kadar sarılır.
      expect(tester.widget<Text>(inBar(find.text('Ev A'))).maxLines, 2);
    });

    testWidgets('ev adı telefonda kesilmez: uzun ad iki satıra sarılır (360 dp)', (tester) async {
      await pumpReady(
        tester,
        const DashboardPage(),
        role: 'owner',
        home: testHome(name: 'Yılmaz Ailesi'),
        size: const Size(360, 800),
      );
      final title = inBar(find.text('Yılmaz Ailesi'));
      expect(title, findsOneWidget);
      expect(exceeded(tester, title), isFalse, reason: 'ev adı "Y…" gibi kesik kalmaz');
    });

    testWidgets('yerel modda dar çubuk: hap kabuğu yok; durum etiketinde bağlantı kipi (Yerel Ağ) yazar', (tester) async {
      final h = await anonymousLocalHarness();
      addTearDown(h.dispose);
      await pumpPage(tester, h.state, const DashboardPage(), size: const Size(360, 800));
      await tester.pump(const Duration(milliseconds: 100));

      expect(inBar(find.byType(GlassPill)), findsNothing);
      final label = tester.widget<Semantics>(find.byKey(const Key('text_connection'))).properties.label ?? '';
      expect(label, contains('Yerel Ağ'), reason: 'durum metni etikette');
    });

    // Taşma yok + 64 dp + disk >= 48 dp: roller x ekran x yazı ölçeği (en zor birleşimler).
    const matrix = <({Size size, double scale})>[
      (size: Size(320, 640), scale: 1.5),
      (size: Size(320, 640), scale: 2.0),
      (size: Size(360, 740), scale: 1.0),
      (size: Size(360, 740), scale: 2.0),
      (size: Size(412, 800), scale: 1.5),
      (size: Size(800, 900), scale: 1.0),
    ];
    for (final role in <String>['user', 'super_user', 'service_user']) {
      for (final cell in matrix) {
        testWidgets('çubuk yüksekliği 64 dp, taşma yok, her cam disk >= 48x48 dp: $role ${cell.size.width.toInt()} dp x${cell.scale}',
            (tester) async {
          await pumpReady(
            tester,
            const DashboardPage(),
            role: 'owner',
            globalRole: role,
            size: cell.size,
            textScale: cell.scale,
          );
          await tester.pump(const Duration(milliseconds: 100));
          expect(tester.takeException(), isNull);
          expect(tester.getSize(find.byType(AppBar)).height, 64);
          for (final name in [
            'nav_menu',
            'nav_qr',
            'nav_settings',
            'nav_family',
            'nav_doctor',
            'nav_refresh',
            'nav_profile',
          ]) {
            final f = byKeyName(name);
            if (f.evaluate().isEmpty) continue;
            final box = tester.getSize(f);
            expect(box.width, greaterThanOrEqualTo(48), reason: name);
            expect(box.height, greaterThanOrEqualTo(48), reason: name);
          }
        });
      }
    }

    for (final theme in <ThemeMode>[ThemeMode.dark, ThemeMode.light]) {
      for (final width in <double>[360, 800]) {
        testWidgets('erişilebilirlik kılavuzları: ${theme.name} tema, ${width.toInt()} dp (ev sahibi)', (tester) async {
          final handle = tester.ensureSemantics();
          try {
            await pumpReady(
              tester,
              const DashboardPage(),
              role: 'owner',
              home: testHome(name: 'Yılmaz Ailesi'),
              size: Size(width, 1600),
              themeMode: theme,
            );
            await tester.pump(const Duration(milliseconds: 200));
            await expectLater(tester, meetsGuideline(textContrastGuideline));
            await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
            await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
          } finally {
            handle.dispose();
          }
        });
      }
    }

    testWidgets('birden çok daire (360 dp): ev değiştirici ≥ 48 dp, okunur etiketli ve dokununca daire seçici açılır',
        (tester) async {
      final handle = tester.ensureSemantics();
      try {
        await pumpReady(
          tester,
          const DashboardPage(),
          role: 'owner',
          size: const Size(360, 800),
          configure: (h) => h.cloud.homes = <HomeModel>[testHome(), testHome(id: kHomeB, name: 'Yazlık')],
        );
        final switcher = byKeyName('nav_home_switcher');
        expect(switcher, findsOneWidget);
        expect(tester.getSize(switcher).height, greaterThanOrEqualTo(48));
        // Durum + ad tek düğümde ("ev adı, durum"): ev değiştirici etiketsiz kalmaz.
        expect(tester.getSemantics(switcher).label, contains('Ev A'));
        expect(tester.takeException(), isNull);
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));

        await tester.tap(switcher);
        await tester.pumpAndSettle();
        expect(byKeyName('sheet_home_switcher'), findsOneWidget);
      } finally {
        handle.dispose();
      }
    });

    testWidgets('avatarın görsel sağ kenarı içerik oluğuna (16 dp) oturur', (tester) async {
      await pumpReady(tester, const DashboardPage(), role: 'owner', size: const Size(360, 800));
      final avatar = tester.getRect(byKeyName('nav_profile')); // 48 dp kutu; 40 dp orb kutunun içinde 4 dp içeride
      expect(360 - (avatar.right - 4), closeTo(16, 2));
    });
  });

  group('konsol çubuğu', () {
    testWidgets('geniş çubukta başlık + slogan: slogan ham metin (hap/canlı nokta DEĞİL, durum gibi görünmez)', (tester) async {
      await pumpReady(tester, const DashboardPage(), role: 'owner', globalRole: 'super_user', size: const Size(800, 900));

      expect(inBar(find.text('Süper Yönetici Konsolu')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('text_connection'))).data, 'AHBU Altyapı & Servis Denetimi');
      expect(inBar(find.byType(GlassPill)), findsNothing, reason: 'slogan durum değildir: hap/nokta yok');
      expect(inBar(find.byType(GlowDot)), findsNothing);
    });

    testWidgets('telefonda (360 dp) slogan çizilmez, başlık iki satıra sarılır ve kesilmez', (tester) async {
      await pumpReady(tester, const DashboardPage(), role: 'owner', globalRole: 'super_user', size: const Size(360, 800));

      expect(find.byKey(const Key('text_connection')), findsNothing);
      final title = inBar(find.byWidgetPredicate(
        (w) => w is Text && (w.data == 'Süper Yönetici Konsolu' || w.data == 'Süper Yönetici'),
      ));
      expect(title, findsOneWidget);
      expect(exceeded(tester, title), isFalse);
      expect(tester.widget<Text>(title).maxLines, 2);
    });

    testWidgets('servis konsolu: telefonda başlık yine okunur (tam ya da kısa biçim)', (tester) async {
      await pumpReady(tester, const DashboardPage(), role: 'owner', globalRole: 'service_user', size: const Size(360, 800));
      final title = inBar(find.byWidgetPredicate(
        (w) => w is Text && (w.data == 'Yetkili Servis Konsolu' || w.data == 'Yetkili Servis'),
      ));
      expect(title, findsOneWidget);
      expect(exceeded(tester, title), isFalse);
    });

    testWidgets('menü diskinin görsel sol kenarı içerik oluğuna (16 dp) oturur', (tester) async {
      await pumpReady(tester, const DashboardPage(), role: 'owner', globalRole: 'super_user', size: const Size(360, 800));
      final menu = tester.getRect(byKeyName('nav_menu')); // 48 dp kutu; 44 dp disk kutunun içinde 2 dp içeride
      expect(menu.left + 2, closeTo(16, 2));
    });
  });

  group('GlassPill (ortak rol/durum hapı)', () {
    // Düz ThemeData: AppTheme (google_fonts) testte ağ/yazı tipi yüklemeye çalışır; hap yalnız parlaklığı okur.
    Widget host(Widget child, {Brightness brightness = Brightness.dark}) => MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: Scaffold(body: Center(child: child)),
        );

    testWidgets('chromeWidth, hapın GERÇEK genişliğiyle uyuşur (üst çubuk "sığar mı" ölçümü dürüst)', (tester) async {
      await tester.pumpWidget(host(GlassPill(
        color: AppFamilies.emerald.base,
        label: 'Sistem Hazır',
        maxLines: 1,
        leading: const SizedBox(width: 8, height: 8),
      )));
      final pill = tester.getSize(find.byType(GlassPill)).width;
      final label = tester.getSize(find.text('Sistem Hazır')).width;
      expect(pill, closeTo(label + GlassPill.chromeWidth(leadingWidth: 8), 0.5));

      await tester.pumpWidget(host(GlassPill(color: AppFamilies.cyan.base, label: 'ENVANTER', maxLines: 1)));
      expect(
        tester.getSize(find.byType(GlassPill)).width,
        closeTo(tester.getSize(find.text('ENVANTER')).width + GlassPill.chromeWidth(), 0.5),
      );
    });

    testWidgets('etiket rengi her ailede ve iki temada kendi yüzeyinde AA (≥ 4.5:1)', (tester) async {
      for (final brightness in Brightness.values) {
        await tester.pumpWidget(host(
          Column(
            children: [
              for (final family in AppFamilies.all) GlassPill(color: family.base, label: family.name),
            ],
          ),
          brightness: brightness,
        ));
        // Tema değişimi `AnimatedTheme` ile 200 ms geçişlidir: bitmeden `Theme.of` eski parlaklığı verir.
        await tester.pump(const Duration(milliseconds: 400));
        final tokens = SurfaceTokens.of(brightness);
        for (final family in AppFamilies.all) {
          final text = tester.widget<Text>(find.text(family.name));
          final fg = text.style!.color!;
          // Hapın en zor zemini: gradyanın iki ucundan kontrastı düşük olan.
          for (final bg in [
            Color.alphaBlend(family.base.withValues(alpha: 0.20), tokens.cardTop),
            Color.alphaBlend(family.base.withValues(alpha: 0.08), tokens.cardBottom),
          ]) {
            expect(wcagContrast(fg, bg), greaterThanOrEqualTo(4.5), reason: '${family.name} ${brightness.name}');
          }
        }
      }
    });

    testWidgets('maxLines > 1: dar yerde etiket satıra sarılır (kesilmez); maxLines 1: tek satır + üç nokta', (tester) async {
      const label = 'SÜPER YÖNETİCİ KONSOLU';
      await tester.pumpWidget(host(SizedBox(width: 200, child: GlassPill(color: AppFamilies.violet.base, label: label))));
      final wrapped = find.text(label);
      expect(tester.widget<Text>(wrapped).softWrap, isTrue);
      expect(tester.renderObject<RenderParagraph>(wrapped).didExceedMaxLines, isFalse, reason: '2 satıra sığar, kesilmez');
      expect(tester.getSize(wrapped).height, greaterThan(14), reason: 'iki satır yüksekliği');

      await tester.pumpWidget(
        host(SizedBox(width: 200, child: GlassPill(color: AppFamilies.violet.base, label: label, maxLines: 1))),
      );
      expect(tester.widget<Text>(find.text(label)).softWrap, isFalse);
    });
  });
}
