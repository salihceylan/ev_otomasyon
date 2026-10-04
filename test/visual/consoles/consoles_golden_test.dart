@Tags(['visual'])
library;

// Konsollar (WP-V5 / WP-F3) görsel galerisi: süper yönetici konsolu, yetkili servis konsolu (içerik / yükleniyor iskeleti /
// hata kartı), çekmece (süper + servis), profil diyaloğu (süper + ev sahibi; ev sahibi için ayrıca gerçekçi 360x740
// kısa ekran) ve ev sahibi panosunun üst çubuğu (uzun ev adı; çevrimdışı durum). Koyu + açık, yazı ölçeği 1.0 + 1.5,
// 360 dp telefon; tablet (800 dp) yalnız ölçek 1.0; bazı durumlarda en küçük telefon (320 dp) 1.5 + 2.0. Gerçek Roboto +
// MaterialIcons; MotionScope(full) + sabit saat.
//
// Yakalama sınırı `MaterialApp.builder` içindedir ve Navigator'ı KAPSAR: diyalog / çekmece / açılır menü rotaları kök
// Overlay'de durur (sınır `home` altında olsaydı profil diyaloğu hiçbir PNG'de görünmezdi). Tuval yüksekliği ölçek 1.5'te
// `scaleFactor` ile büyür (içerik uzar; sabit tuval alt bölümleri kesiyordu). Marka logosu önbelleğe ısıtılır.
//
//   flutter test --tags visual --update-goldens test/visual/consoles   -> goldens/*.png üretir
//   AHBU_VISUAL=1 flutter test --tags visual test/visual/consoles        -> kayıtlı PNG'lerle karşılaştırır

import 'dart:async';

import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/motion/motion.dart';
import 'package:ev_otomasyon/ui/pages/dashboard_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/support.dart';
import '../../ui/e1_helpers.dart';
import '../support/golden_support.dart';

typedef _Setup = Future<StateHarness> Function(WidgetTester tester);

/// Sayfa kurulduktan sonraki ek adım (çekmece açma / profil diyaloğu açma).
typedef _After = Future<void> Function(WidgetTester tester);

class _Case {
  const _Case(
    this.name,
    this.setup, {
    this.after,
    this.phone = const Size(360, 1500),
    this.tablet = const Size(800, 1500),
    this.small,
    this.scaleFactor = 1.6,
    this.tabletToo = true,
  });

  final String name;
  final _Setup setup;
  final _After? after;

  /// Telefon (360 dp) tuvali: yazı ölçeği 1.0'daki yükseklik; ölçek 1.5'te yükseklik [scaleFactor] ile çarpılır
  /// (büyük yazıda içerik uzar; sabit tuval alt bölümleri kesiyordu).
  final Size phone;
  final Size tablet;

  /// En küçük telefon (320 dp) tuvali (yalnız verilirse): ölçek 1.5 ve 2.0.
  final Size? small;
  final double scaleFactor;

  /// Tablet (800 dp) varyantları da üretilsin mi?
  final bool tabletToo;

  Size sizeFor(String device, double scale) {
    switch (device) {
      case 'tablet':
        return tablet;
      case 'small':
        return Size(small!.width, small!.height * (scale > 1 ? scaleFactor : 1));
      default:
        return Size(phone.width, phone.height * (scale > 1 ? scaleFactor : 1));
    }
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _openDrawer(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('nav_menu')));
  await _settle(tester);
}

Future<void> _openProfile(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('nav_profile')));
  await _settle(tester);
}

Future<void> _openOverflow(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('nav_overflow')));
  await _settle(tester);
}

Future<StateHarness> _ready(
  WidgetTester t, {
  required String globalRole,
  HomeModel? home,
  void Function(StateHarness h)? configure,
}) async {
  final h = (await t.runAsync(() => e1Ready(role: 'owner', globalRole: globalRole, home: home, configure: configure)))!;
  addTearDown(h.dispose);
  return h;
}

/// Yükleme durumu için tutulan kapılar: görüntü alındıktan sonra açılır (bekleyen zaman aşımı kalmasın).
final List<Completer<void>> _gates = <Completer<void>>[];

// Tuval yükseklikleri ölçek 1.0 içindir; ölçek 1.5'te `scaleFactor` ile büyür (içerik uzar, alt bölümler kesilmez).
final List<_Case> _cases = <_Case>[
  _Case('super_console', (t) => _ready(t, globalRole: 'super_user'),
      phone: const Size(360, 1250), small: const Size(320, 1250)),
  _Case('service_console', (t) => _ready(t, globalRole: 'service_user'),
      phone: const Size(360, 1400), scaleFactor: 1.75),
  _Case('super_loading', (t) async {
    final gate = Completer<void>();
    final h = await _ready(t, globalRole: 'super_user', configure: (h) => h.e1.summaryGate = gate);
    _gates.add(gate);
    return h;
  }, phone: const Size(360, 1000), tablet: const Size(800, 900)),
  _Case('super_error', (t) => _ready(t, globalRole: 'super_user', configure: (h) => h.e1.summaryError = kServerError),
      phone: const Size(360, 1100), tablet: const Size(800, 900)),
  _Case('drawer_super', (t) => _ready(t, globalRole: 'super_user'),
      after: _openDrawer, phone: const Size(360, 900), tablet: const Size(800, 900), scaleFactor: 1.7),
  _Case('drawer_service', (t) => _ready(t, globalRole: 'service_user'),
      after: _openDrawer, phone: const Size(360, 900), tablet: const Size(800, 900), scaleFactor: 1.7),
  _Case('profile_super', (t) => _ready(t, globalRole: 'super_user'),
      after: _openProfile, phone: const Size(360, 1100), tablet: const Size(800, 1100), scaleFactor: 1.8),
  _Case('profile_owner', (t) => _ready(t, globalRole: 'user'),
      after: _openProfile, phone: const Size(360, 1300), tablet: const Size(800, 1300), scaleFactor: 1.8),
  // Gerçekçi telefon yüksekliği (360x740): diyalog kendi içinde kaydırılır; "Kapat" eylemi alta sabit kalır.
  _Case('profile_owner_short', (t) => _ready(t, globalRole: 'user'),
      after: _openProfile, phone: const Size(360, 740), scaleFactor: 1.0, tabletToo: false),
  // Telefonda ⋮ menüsü: aile yönetimi + mod + doktor + yenile (okunabilir simge renkleri).
  _Case('bar_owner_menu', (t) => _ready(t, globalRole: 'user', home: testHome(name: 'Yılmaz Ailesi')),
      after: _openOverflow, phone: const Size(360, 460), scaleFactor: 1.3, tabletToo: false),
  // Pano çevrimdışı: durum göstergesi NOKTA değil simge (renk tek ipucu değil); geniş çubukta hap, dar çubukta simge.
  _Case('bar_offline', (t) async {
    final h = await _ready(t, globalRole: 'user', home: testHome(name: 'Yılmaz Ailesi'));
    h.state.setPresenceForTesting(DevicePresence.offline);
    return h;
  }, phone: const Size(360, 330), tablet: const Size(800, 330), scaleFactor: 1.0),
  // Ev sahibi panosunun üst çubuğu: gerçekçi uzun ev adı ('Yılmaz Ailesi'), 360/320 dp ve büyük yazı.
  _Case('bar_owner', (t) => _ready(t, globalRole: 'user', home: testHome(name: 'Yılmaz Ailesi')),
      phone: const Size(360, 330),
      tablet: const Size(800, 330),
      small: const Size(320, 330),
      scaleFactor: 1.0),
];

Future<void> _pumpApp(
  WidgetTester tester,
  AutomationState state, {
  required GlobalKey boundaryKey,
  required Brightness brightness,
  required double textScale,
  required Size size,
}) async {
  debugDisableShadows = false;
  const dpr = 2.0;
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = Size(size.width * dpr, size.height * dpr);
  addTearDown(tester.view.reset);
  final clock = AmbientClock.fixed(0.65);
  addTearDown(clock.dispose);
  await tester.pumpWidget(
    MotionScope(
      mode: MotionMode.full,
      clock: clock,
      child: ChangeNotifierProvider<AutomationState>.value(
        value: state,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: goldenTheme(Brightness.light),
          darkTheme: goldenTheme(Brightness.dark),
          themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
          // Yakalama sınırı Navigator'ı KAPSAR (MaterialApp.builder): diyalog / çekmece / açılır menü rotaları kök
          // Navigator'ın Overlay'inde durur; sınır `home` altında olsaydı bunlar PNG'ye hiç girmezdi.
          builder: (context, child) => RepaintBoundary(
            key: boundaryKey,
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
          ),
          home: GalleryBackdrop(child: const DashboardPage()),
        ),
      ),
    ),
  );
  await tester.pump();
  // Marka logosu soğuk görsel önbelleğinde ilk karede çözülmemiş kalmasın (ilk PNG'de boş halka çıkıyordu).
  await tester.runAsync(
    () => precacheImage(const AssetImage('assets/images/round_app_logo.png'), tester.element(find.byType(Scaffold).first)),
  );
  await tester.pump();
  await _settle(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Konsol galerisi', skip: visualSkipReason, () {
    setUpAll(loadGoldenFonts);

    for (final c in _cases) {
      final variants = <({String device, Brightness b, double scale})>[
        for (final b in [Brightness.dark, Brightness.light])
          for (final scale in [1.0, 1.5]) (device: 'phone', b: b, scale: scale),
        if (c.tabletToo)
          for (final b in [Brightness.dark, Brightness.light]) (device: 'tablet', b: b, scale: 1.0),
        if (c.small != null)
          for (final b in [Brightness.dark, Brightness.light])
            for (final scale in [1.5, 2.0]) (device: 'small', b: b, scale: scale),
      ];
      for (final v in variants) {
        final tag = '${c.name}_${v.device}_${v.b.name}_${v.scale}';
        testWidgets('konsol: $tag', (tester) async {
          final h = await c.setup(tester);
          final key = GlobalKey();
          await _pumpApp(
            tester,
            h.state,
            boundaryKey: key,
            brightness: v.b,
            textScale: v.scale,
            size: c.sizeFor(v.device, v.scale),
          );
          if (c.after != null) await c.after!(tester);
          expect(tester.takeException(), isNull, reason: tag);
          await expectGolden(tester, key, '$tag.png', pixelRatio: v.scale > 1 ? 1.0 : 1.5);
          for (final g in _gates) {
            if (!g.isCompleted) g.complete();
          }
          _gates.clear();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
        });
      }
    }
  });
}
