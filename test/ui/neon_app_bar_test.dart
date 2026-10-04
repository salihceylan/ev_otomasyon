import 'package:ev_otomasyon/ui/pages/device_inventory_page.dart';
import 'package:ev_otomasyon/ui/pages/device_settings_page.dart';
import 'package:ev_otomasyon/ui/pages/family/family_members_page.dart';
import 'package:ev_otomasyon/ui/pages/scheduled_rules_page.dart';
import 'package:ev_otomasyon/ui/pages/service_management_page.dart';
import 'package:ev_otomasyon/ui/pages/service_mode_page.dart';
import 'package:ev_otomasyon/ui/pages/service_subscribers_page.dart';
import 'package:ev_otomasyon/ui/theme/app_theme.dart';
import 'package:ev_otomasyon/ui/theme/feature_accent.dart';
import 'package:ev_otomasyon/ui/theme/tokens.dart';
import 'package:ev_otomasyon/ui/widgets/neon_app_bar.dart';
import 'package:ev_otomasyon/ui/widgets/orb/orb.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'e1_helpers.dart';

/// `NeonAppBar` (WP-V9 A): ikincil sayfaların ortak üst çubuğu. `Scaffold.appBar` bir [PreferredSizeWidget]'tır ve GERÇEK
/// bir `AppBar` döndürür (alt sınıf değil); geri düğmesi cam disktir ve `WidgetTester.pageBack` bulur; başlık metni aynen;
/// eylem anahtarları/ipuçları korunur; 64 dp, ölçek 1.5/2.0 ve dar ekranda taşma/kesilme yok.
///
/// Not: `flutter test`'te yazı tipi Ahem'dir (her harf 1 em genişliğinde): kesilme/taşma sınamaları en kötü durumdur.
void main() {
  // Düz ThemeData: AppTheme (google_fonts) testte ağ/yazı tipi yüklemeye çalışır; çubuk yalnız parlaklığı okur.
  Widget host(
    PreferredSizeWidget bar, {
    Brightness brightness = Brightness.dark,
    double scale = 1.0,
    Widget? body,
  }) =>
      MaterialApp(
        theme: ThemeData(brightness: brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(appBar: bar, body: body ?? const SizedBox.expand()),
      );

  /// Kök rota üstüne iter: geri gidilebilir bir sayfada çubuk.
  Future<void> pumpPushed(WidgetTester tester, PreferredSizeWidget bar, {double scale = 1.0, Size? size}) async {
    if (size != null) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                key: const Key('open'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => Scaffold(appBar: bar, body: const SizedBox.expand())),
                ),
                child: const Text('Aç'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();
  }

  group('yapı', () {
    testWidgets('GERÇEK bir AppBar döndürür (alt sınıf değil): find.byType(AppBar) tam 1; 64 dp, şeffaf, ton yok', (tester) async {
      await tester.pumpWidget(host(const NeonAppBar(title: 'Cihaz Envanteri', feature: AppFeature.inventory, icon: Icons.inventory_2_rounded)));
      expect(find.byType(AppBar), findsOneWidget);
      final bar = tester.widget<AppBar>(find.byType(AppBar));
      expect(bar.runtimeType, AppBar, reason: 'alt sınıf değil, AppBar');
      expect(bar.toolbarHeight, 64);
      expect(tester.getSize(find.byType(AppBar)).height, 64);
      expect(bar.backgroundColor, Colors.transparent);
      expect(bar.surfaceTintColor, Colors.transparent, reason: 'kaydırınca tonlanmaz');
      expect(bar.scrolledUnderElevation, 0);
      expect(bar.elevation, 0);
      expect(bar.automaticallyImplyLeading, isFalse, reason: 'geri düğmesini NeonAppBar kendisi çizer (cam disk)');
      expect(bar.centerTitle, isFalse);
    });

    testWidgets('preferredSize: 64 dp + bottom (TabBar) yüksekliği', (tester) async {
      const plain = NeonAppBar(title: 'A');
      expect(plain.preferredSize.height, 64);
      const tabs = PreferredSize(preferredSize: Size.fromHeight(48), child: SizedBox(height: 48));
      expect(const NeonAppBar(title: 'A', bottom: tabs).preferredSize.height, 64 + 48);
    });

    testWidgets('bottom (TabBar) çubuğun altına çizilir; çubuk 64 + 48 dp', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: DefaultTabController(
            length: 2,
            child: Scaffold(
              appBar: NeonAppBar(
                title: 'Servis Yönetimi',
                bottom: const TabBar(tabs: [Tab(text: 'Hesaplar'), Tab(text: 'Araçlar')]),
              ),
              body: const TabBarView(children: [SizedBox(), SizedBox()]),
            ),
          ),
        ),
      );
      expect(find.byType(TabBar), findsOneWidget);
      expect(tester.getSize(find.byType(AppBar)).height, 64 + kTextTabBarHeight);
      expect(find.text('Hesaplar'), findsOneWidget);
    });
  });

  group('başlık, alt başlık, orb', () {
    testWidgets('başlık metni AYNEN; AppText.title 18 sp / w700; sığmazsa 2 satıra sarılır', (tester) async {
      await tester.pumpWidget(host(const NeonAppBar(title: 'Abonelerim & Cihaz Atama', titleKey: Key('t'))));
      final text = tester.widget<Text>(find.byKey(const Key('t')));
      expect(text.data, 'Abonelerim & Cihaz Atama');
      expect(text.style!.fontSize, AppText.title);
      expect(text.style!.fontWeight, FontWeight.w700);
      expect(text.maxLines, 2);
      expect(text.softWrap, isTrue);
      expect(find.byType(FittedBox), findsWidgets, reason: 'sığmayan blok küçülür (taşma yok)');
    });

    testWidgets('dar çubukta uzun başlık KESİLMEZ: iki satıra sarılır (didExceedMaxLines false)', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      // Ahem: harf başına 18 dp; 24 harf = 432 dp > başlık alanı (~200 dp): iki satır gerekir ve sığar.
      await tester.pumpWidget(host(const NeonAppBar(title: 'Abonelerim Cihaz Atama', titleKey: Key('t'))));
      final render = tester.renderObject<RenderParagraph>(find.byKey(const Key('t')));
      expect(render.didExceedMaxLines, isFalse);
      expect(tester.getSize(find.byKey(const Key('t'))).height, greaterThan(AppText.title * 1.5), reason: 'iki satır yüksekliği');
      expect(tester.takeException(), isNull);
    });

    testWidgets('yazı ölçeği 2.0: blok en çok 1.3x büyür (çubuk 64 dp sabit; pano üst çubuğuyla aynı sınır)', (tester) async {
      await tester.pumpWidget(host(const NeonAppBar(title: 'Ayarlar', titleKey: Key('t'))));
      final base = tester.getSize(find.byKey(const Key('t'))).height;
      await tester.pumpWidget(host(const NeonAppBar(title: 'Ayarlar', titleKey: Key('t')), scale: 2.0));
      final big = tester.getSize(find.byKey(const Key('t'))).height;
      expect(big / base, closeTo(NeonAppBar.maxTextScale, 0.05));
      expect(NeonAppBar.maxTextScale, 1.3);
      expect(tester.getSize(find.byType(AppBar)).height, 64);
    });

    testWidgets('alt başlık: yalnız verilince; 12.5 sp (>= 12), soluk (getTextMuted)', (tester) async {
      await tester.pumpWidget(host(const NeonAppBar(title: 'Servis Paneli')));
      expect(find.text('Kurulum, test ve yönetim'), findsNothing);

      await tester.pumpWidget(host(const NeonAppBar(title: 'Servis Paneli', subtitle: 'Kurulum, test ve yönetim')));
      final sub = tester.widget<Text>(find.text('Kurulum, test ve yönetim'));
      expect(sub.style!.fontSize, AppText.caption);
      expect(sub.style!.fontSize!, greaterThanOrEqualTo(AppTouch.minFontSize));
      final context = tester.element(find.text('Kurulum, test ve yönetim'));
      expect(sub.style!.color, AppTheme.getTextMuted(context));
    });

    for (final brightness in Brightness.values) {
      testWidgets('alt başlık rengi sayfa zemininde AA (>= 4.5:1): ${brightness.name}', (tester) async {
        await tester.pumpWidget(host(const NeonAppBar(title: 'T', subtitle: 'Alt başlık'), brightness: brightness));
        await tester.pump(const Duration(milliseconds: 400)); // tema geçişi
        final color = tester.widget<Text>(find.text('Alt başlık')).style!.color!;
        final page = brightness == Brightness.dark ? AppTheme.bgDark : AppTheme.bgLight;
        expect(wcagContrast(color, page), greaterThanOrEqualTo(4.5));
      });
    }

    testWidgets('orb: icon verilince OrbIconBadge ~32 dp; rengi özelliğin ailesi (featureFamily); icon yoksa orb yok', (tester) async {
      for (final feature in AppFeature.values) {
        await tester.pumpWidget(host(NeonAppBar(title: 'T', feature: feature, icon: Icons.star_rounded)));
        final orb = tester.widget<OrbIconBadge>(find.byType(OrbIconBadge));
        expect(orb.family, featureFamily(feature), reason: feature.name);
        final box = find.ancestor(of: find.byType(OrbIconBadge), matching: find.byType(FittedBox)).first;
        expect(tester.getSize(box), const Size(32, 32), reason: 'orb ~32 dp');
      }
      await tester.pumpWidget(host(const NeonAppBar(title: 'T', feature: AppFeature.inventory)));
      expect(find.byType(OrbIconBadge), findsNothing);
    });

    testWidgets('family: özellikten önceliklidir; ikisi de yoksa marka camgöbeği', (tester) async {
      await tester.pumpWidget(host(const NeonAppBar(title: 'T', feature: AppFeature.inventory, family: AppFamilies.rose, icon: Icons.star)));
      expect(tester.widget<OrbIconBadge>(find.byType(OrbIconBadge)).family, AppFamilies.rose);
      await tester.pumpWidget(host(const NeonAppBar(title: 'T', icon: Icons.star)));
      expect(tester.widget<OrbIconBadge>(find.byType(OrbIconBadge)).family, AppFamilies.cyan);
    });

    testWidgets('orb anlamdan hariç: ekran okuyucu başlığı okur, simgeyi okumaz', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(host(const NeonAppBar(title: 'Cihaz Envanteri', feature: AppFeature.inventory, icon: Icons.inventory_2_rounded)));
      expect(find.bySemanticsLabel('Cihaz Envanteri'), findsWidgets);
      expect(find.descendant(of: find.byType(OrbIconBadge), matching: find.byType(Semantics)).evaluate().where((e) {
        final w = e.widget as Semantics;
        return w.properties.label != null;
      }), isEmpty);
      handle.dispose();
    });
  });

  group('geri düğmesi', () {
    testWidgets('kök rotada geri düğmesi YOK; başlık 16 dp içerik oluğundan başlar', (tester) async {
      await tester.pumpWidget(host(const NeonAppBar(title: 'Ayarlar', titleKey: Key('t'))));
      expect(find.byKey(const Key('nav_back')), findsNothing);
      expect(tester.getTopLeft(find.byKey(const Key('t'))).dx, closeTo(16, 0.5));
    });

    testWidgets('geri gidilebilen rotada cam disk (GlassIconButton) çizilir: >= 48 dp, görsel sol kenar 16 dp, ipucu "Back"', (tester) async {
      await pumpPushed(tester, const NeonAppBar(title: 'Ayarlar'));
      final back = find.byKey(const Key('nav_back'));
      expect(back, findsOneWidget);
      expect(tester.widget(back), isA<GlassIconButton>());
      final size = tester.getSize(back);
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
      expect(tester.getTopLeft(back).dx + 2, closeTo(16, 0.5), reason: '44 dp disk 48 dp kutuda 2 dp içeride');
      expect(find.byTooltip('Back'), findsOneWidget, reason: 'eski BackButton ile aynı ipucu: WidgetTester.pageBack bulur');
      expect(find.byType(BackButton), findsNothing, reason: 'Material geri oku yerine cam disk');
    });

    testWidgets('dokununca sayfa kapanır; pageBack de çalışır', (tester) async {
      await pumpPushed(tester, const NeonAppBar(title: 'Ayarlar'));
      await tester.tap(find.byKey(const Key('nav_back')));
      await tester.pumpAndSettle();
      expect(find.byType(NeonAppBar), findsNothing);
      expect(find.byKey(const Key('open')), findsOneWidget);

      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      expect(find.byType(NeonAppBar), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(NeonAppBar), findsNothing);
    });

    testWidgets('PopScope(canPop: false) kapısına uyar: Navigator.maybePop (eski BackButton davranışı)', (tester) async {
      var blocked = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                key: const Key('open'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => PopScope(
                      canPop: false,
                      onPopInvokedWithResult: (didPop, _) {
                        if (!didPop) blocked++;
                      },
                      child: const Scaffold(appBar: NeonAppBar(title: 'Kilitli'), body: SizedBox.expand()),
                    ),
                  ),
                ),
                child: const Text('Aç'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('nav_back')));
      await tester.pumpAndSettle();
      expect(find.byType(NeonAppBar), findsOneWidget, reason: 'kapı sayfadan çıkışı engeller');
      expect(blocked, 1);
    });

    testWidgets('automaticallyImplyLeading: false ⇒ geri düğmesi yok (geri gidilebilir rotada da)', (tester) async {
      await pumpPushed(tester, const NeonAppBar(title: 'Meşgul', automaticallyImplyLeading: false));
      expect(find.byKey(const Key('nav_back')), findsNothing);
      expect(find.byTooltip('Back'), findsNothing);
    });

    testWidgets('anlam: geri düğmesi tek "button" düğümü (etiket Back)', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpPushed(tester, const NeonAppBar(title: 'Ayarlar'));
      expect(tester.getSemantics(find.byKey(const Key('nav_back'))), matchesSemantics(label: 'Back', isButton: true, hasTapAction: true, hasEnabledState: true, isEnabled: true));
      handle.dispose();
    });
  });

  group('eylemler', () {
    testWidgets('NeonBarAction: cam disk >= 48 dp, ipucu + anlam etiketi, anahtar çağıranda; dokunuş çalışır', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        host(
          NeonAppBar(
            title: 'Zamanlı Kurallar',
            actions: [
              NeonBarAction(key: const Key('btn_add_rule'), icon: Icons.add_rounded, tooltip: 'Yeni Kural Ekle', onTap: () => taps++),
              NeonBarAction(key: const Key('nav_refresh'), icon: Icons.refresh_rounded, tooltip: 'Yenile', onTap: () {}),
            ],
          ),
        ),
      );
      for (final key in ['btn_add_rule', 'nav_refresh']) {
        final size = tester.getSize(find.byKey(Key(key)));
        expect(size.width, greaterThanOrEqualTo(48), reason: key);
        expect(size.height, greaterThanOrEqualTo(48), reason: key);
      }
      expect(find.byTooltip('Yeni Kural Ekle'), findsOneWidget);
      expect(find.byTooltip('Yenile'), findsOneWidget);
      expect(find.byType(GlassIconButton), findsNWidgets(2));
      await tester.tap(find.byKey(const Key('btn_add_rule')));
      expect(taps, 1);

      // Son diskin görsel sağ kenarı 16 dp içerik oluğuna oturur (44 dp disk 48 dp kutuda 2 dp içeride).
      final last = tester.getTopRight(find.byKey(const Key('nav_refresh')));
      expect(800 - (last.dx - 2), closeTo(16, 0.5));
    });

    testWidgets('anlam: eylem tek etiketli düğüm (ipucu anlamdan hariç, çift okuma yok)', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        host(NeonAppBar(title: 'T', actions: [NeonBarAction(key: const Key('a'), icon: Icons.refresh_rounded, tooltip: 'Yenile', onTap: () {})])),
      );
      expect(find.bySemanticsLabel('Yenile'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('onTap null ⇒ pasif eylem: dokunuş yok, anlam devre dışı', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        host(const NeonAppBar(title: 'T', actions: [NeonBarAction(key: Key('a'), icon: Icons.refresh_rounded, tooltip: 'Yenile', onTap: null)])),
      );
      final disk = find.descendant(of: find.byKey(const Key('a')), matching: find.byType(GlassIconButton));
      expect(tester.getSemantics(disk), matchesSemantics(label: 'Yenile', isButton: true, hasEnabledState: true, isEnabled: false));
      handle.dispose();
    });
  });

  // Taşma / kesilme: telefon x ölçek x en uzun içerik (geri + orb + başlık + alt başlık + 2 eylem).
  group('yerleşim matrisi: 64 dp, taşma yok, başlık eylemlerle çakışmaz', () {
    for (final width in <double>[320, 360, 412]) {
      for (final scale in <double>[1.0, 1.5, 2.0]) {
        testWidgets('${width.toInt()} dp x$scale', (tester) async {
          const title = 'Abonelerim & Cihaz Atama (uzun başlık)';
          await pumpPushed(
            tester,
            NeonAppBar(
              title: title,
              subtitle: 'Karekodlar, Seri No & Donanım Takibi',
              feature: AppFeature.subscribers,
              icon: Icons.people_alt_rounded,
              actions: [
                NeonBarAction(key: const Key('a1'), icon: Icons.add_rounded, tooltip: 'Ekle', onTap: () {}),
                NeonBarAction(key: const Key('a2'), icon: Icons.refresh_rounded, tooltip: 'Yenile', onTap: () {}),
              ],
            ),
            scale: scale,
            size: Size(width, 780),
          );
          expect(tester.takeException(), isNull);
          expect(tester.getSize(find.byType(AppBar)).height, 64);
          final titleRect = tester.getRect(find.text(title));
          final bar = tester.getRect(find.byType(AppBar));
          expect(titleRect.left, greaterThanOrEqualTo(tester.getRect(find.byType(OrbIconBadge)).right - 1), reason: 'orb ile çakışmaz');
          expect(titleRect.right, lessThanOrEqualTo(tester.getTopLeft(find.byKey(const Key('a1'))).dx + 0.5), reason: 'eylemlerle çakışmaz');
          expect(titleRect.top, greaterThanOrEqualTo(bar.top - 0.5));
          expect(titleRect.bottom, lessThanOrEqualTo(bar.bottom + 0.5), reason: 'çubuktan taşmaz');
          final sub = tester.getRect(find.text('Karekodlar, Seri No & Donanım Takibi'));
          expect(sub.bottom, lessThanOrEqualTo(bar.bottom + 0.5));
          expect(sub.right, lessThanOrEqualTo(tester.getTopLeft(find.byKey(const Key('a1'))).dx + 0.5));
        });
      }
    }
  });

  // Gerçek sayfalar: her biri NeonAppBar kullanır (başlık metni aynen; eylem anahtarları korunur).
  group('sayfalar', () {
    Future<void> expectBar(WidgetTester tester, String title, {AppFeature? feature}) async {
      expect(find.byType(NeonAppBar), findsOneWidget);
      expect(find.descendant(of: find.byType(AppBar), matching: find.text(title)), findsOneWidget);
      expect(tester.getSize(find.byType(AppBar)).height, anyOf(64, 64 + kTextTabBarHeight, 64 + 3, 64 + 72));
      if (feature != null) {
        expect(tester.widget<NeonAppBar>(find.byType(NeonAppBar)).feature, feature);
        expect(tester.widget<OrbIconBadge>(find.descendant(of: find.byType(AppBar), matching: find.byType(OrbIconBadge))).family, featureFamily(feature));
      }
    }

    testWidgets('Cihaz Envanteri: orb inventory, alt başlık, btn_refresh', (tester) async {
      await pumpReady(tester, const DeviceInventoryPage(autoLoad: false), globalRole: 'super_user', size: const Size(400, 900));
      await expectBar(tester, 'Cihaz Envanteri', feature: AppFeature.inventory);
      expect(find.text('Karekodlar, Seri No & Donanım Takibi'), findsOneWidget);
      expect(byKeyName('btn_refresh'), findsOneWidget);
      expect(find.byTooltip('Yenile'), findsOneWidget);
    });

    testWidgets('Zamanlı Kurallar: orb rules, btn_add_rule + nav_refresh', (tester) async {
      await pumpReady(tester, const ScheduledRulesPage(), size: const Size(400, 900));
      await expectBar(tester, 'Zamanlı Kurallar', feature: AppFeature.rules);
      expect(byKeyName('btn_add_rule'), findsOneWidget);
      expect(byKeyName('nav_refresh'), findsOneWidget);
      expect(find.byTooltip('Yeni Kural Ekle'), findsOneWidget);
    });

    testWidgets('Servis Yönetimi: orb management, TabBar bottom, btn_refresh', (tester) async {
      await pumpReady(tester, const ServiceManagementPage(autoLoad: false), globalRole: 'super_user', size: const Size(400, 900));
      expect(find.byType(NeonAppBar), findsOneWidget);
      expect(find.byKey(const Key('nav_service_management_title')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('nav_service_management_title'))).data, 'Servis Yönetimi');
      expect(tester.widget<NeonAppBar>(find.byType(NeonAppBar)).feature, AppFeature.management);
      expect(find.byType(TabBar), findsOneWidget);
      expect(find.byKey(const Key('tab_accounts')), findsOneWidget);
      expect(find.byKey(const Key('tab_tools')), findsOneWidget);
      expect(byKeyName('btn_refresh'), findsOneWidget);
    });

    testWidgets('Abonelerim: orb subscribers, btn_refresh', (tester) async {
      await pumpReady(tester, const ServiceSubscribersPage(), globalRole: 'service_user', size: const Size(400, 900));
      await expectBar(tester, 'Abonelerim & Cihaz Atama', feature: AppFeature.subscribers);
      expect(byKeyName('btn_refresh'), findsOneWidget);
    });

    testWidgets('Aile & Misafir: orb family', (tester) async {
      await pumpReady(tester, const FamilyMembersPage(), size: const Size(400, 900));
      await expectBar(tester, 'Aile & Misafir Yönetimi', feature: AppFeature.family);
    });

    testWidgets('Cihaz & Sistem Ayarları: orb settings', (tester) async {
      await pumpReady(tester, const DeviceSettingsPage(), size: const Size(400, 900));
      await expectBar(tester, 'Cihaz & Sistem Ayarları', feature: AppFeature.settings);
    });

    testWidgets('Servis Paneli: orb commissioning, nav_service_title anahtarı, alt başlık', (tester) async {
      await pumpReady(tester, const ServiceModePage(), globalRole: 'service_user', size: const Size(400, 900));
      await expectBar(tester, 'Servis Paneli', feature: AppFeature.commissioning);
      expect(find.byKey(const Key('nav_service_title')), findsOneWidget);
      expect(find.text('Kurulum, test ve yönetim'), findsOneWidget);
    });
  });
}
