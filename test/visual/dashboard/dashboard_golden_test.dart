@Tags(['visual'])
library;

// Pano (WP-V2 DASHBOARD) görsel galerisi: içerik (huzur bandı ile / sakin), yükleme iskeleti, hata, boş/hoş geldin,
// doğrudan mod "anahtar gerekli" ve "geçici kilitli". Koyu + açık, yazı ölçeği 1.0 + 1.5, 360 dp telefon,
// 800x1280 tablet, 1280x800 masaüstü. Gerçek Roboto + MaterialIcons; MotionScope(full) + AmbientClock.fixed.
//
//   flutter test --tags visual --update-goldens test/visual/dashboard   -> goldens/*.png üretir
//   AHBU_VISUAL=1 flutter test --tags visual test/visual/dashboard        -> kayıtlı PNG'lerle karşılaştırır

import 'dart:async';

import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/dashboard/dashboard_app_bar.dart';
import 'package:ev_otomasyon/ui/motion/motion.dart';
import 'package:ev_otomasyon/ui/pages/dashboard_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/support.dart';
import '../../ui/e1_helpers.dart';
import '../support/golden_support.dart';

/// Bir golden durumu: harness'ı (gerçek asenkron bölgede) kurar.
typedef _Setup = Future<StateHarness> Function(WidgetTester tester);

class _Case {
  const _Case(this.name, this.setup, {this.phone = const Size(360, 760), this.wide = const Size(1280, 800), this.fit = false});

  final String name;
  final _Setup setup;

  /// Telefon / geniş yüzeyin EN AZ boyutu (durum ekranları kendi nominal boyunda çekilir).
  final Size phone;
  final Size wide;

  /// `true`: yüzey yüksekliği içeriğe göre ölçülür (nominal boyut alt sınır DEĞİL); uzun içerik ekranları kırpılmaz.
  final bool fit;
}

Map<String, dynamic> _lanStatus() => <String, dynamic>{
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

Future<StateHarness> _direct(WidgetTester tester, int status, Map<String, dynamic> body) async {
  final h = (await tester.runAsync(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final h = StateHarness();
    h.state
      ..setCurrentUserForTesting(const UserModel(id: 'u', email: 'a@b.c', fullName: 'Ayşe Yılmaz', role: 'user'))
      ..setAuthStatusForTesting(AuthStatus.authenticated)
      ..setHomesForTesting(<HomeModel>[testHome()]);
    h.directMock.on('GET', '/api/status', (r) => jsonResponse(_lanStatus()));
    await h.state.setMode(AppMode.direct);
    await h.state.setHost('192.168.1.30');
    h.direct.localKey = 'devicekey-1234';
    await h.state.refresh();
    h.directMock.on('GET', '/api/status', (r) => jsonResponse(body, status: status));
    await h.clock.elapse(const Duration(seconds: 5));
    return h;
  }))!;
  addTearDown(h.dispose);
  return h;
}

Future<StateHarness> _loggedIn(WidgetTester tester, {void Function(StateHarness h)? configure}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final h = StateHarness();
  h.state
    ..setCurrentUserForTesting(const UserModel(id: 'user-1', email: 'a@b.c', fullName: 'Ayşe Yılmaz', role: 'user'))
    ..setAuthStatusForTesting(AuthStatus.authenticated);
  configure?.call(h);
  addTearDown(h.dispose);
  return h;
}

final List<_Case> _cases = <_Case>[
  _Case('content_lit', (t) async {
    final h = (await t.runAsync(() => e1Ready(endpoints: litEndpoints())))!;
    addTearDown(h.dispose);
    return h;
  }, fit: true),
  _Case('content_calm', (t) async {
    final h = (await t.runAsync(() => e1Ready()))!;
    addTearDown(h.dispose);
    return h;
  }, fit: true),
  _Case('loading', (t) async {
    final gate = Completer<void>();
    final h = await _loggedIn(t, configure: (h) => h.cloud.fetchHomesGate = gate);
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    unawaited(h.state.fetchHomes());
    return h;
  }, phone: const Size(360, 760), wide: const Size(1280, 800)),
  _Case('error', (t) async {
    final h = await _loggedIn(t, configure: (h) => h.cloud.fetchHomesError = kServerError);
    await t.runAsync(() => h.state.fetchHomes());
    return h;
  }, phone: const Size(360, 760), wide: const Size(1280, 800)),
  _Case('welcome_claim', (t) async {
    final h = (await t.runAsync(() => e1Ready(endpoints: <EndpointModel>[])))!;
    addTearDown(h.dispose);
    return h;
  }, phone: const Size(360, 900), wide: const Size(1280, 900)),
  _Case('homeless', (t) async {
    final h = await _loggedIn(t);
    await t.runAsync(() => h.state.fetchHomes());
    return h;
  }, phone: const Size(360, 1100), wide: const Size(1280, 900)),
  // Erişim süresi dolmuş misafir (rose durum kartı + "Başka daireye geç"): [StateCard] / [StateActions] kapsamı.
  _Case('guest_expired', (t) async {
    final h = (await t.runAsync(
      () => e1Ready(
        home: guestHome(hours: 1, name: 'Yazlık'),
        configure: (h) => h.e1.homes = <HomeModel>[guestHome(hours: 1, name: 'Yazlık'), testHome(id: kHomeB, name: 'Ev B')],
      ),
    ))!;
    addTearDown(h.dispose);
    h.clock.advance(const Duration(hours: 2));
    return h;
  }, phone: const Size(360, 760), wide: const Size(1280, 800)),
  // Birden çok daire, aktif daire yok: daire seçici ([HomePickerList] SurfaceCard satırları).
  _Case('pick_home', (t) async {
    final h = (await t.runAsync(() => e1Ready()))!;
    addTearDown(h.dispose);
    h.e1.homes = <HomeModel>[
      HomeModel(id: kHomeB, name: 'Yazlık', role: 'resident', mqttTopicId: 'h_other'),
      HomeModel(id: 'home-c', name: 'Ev Ofisi', role: 'owner', mqttTopicId: 'h_office'),
    ];
    await t.runAsync(() => h.state.fetchHomes(autoSelect: false));
    return h;
  }, phone: const Size(360, 760), wide: const Size(1280, 800)),
  _Case('direct_needs_key', (t) => _direct(t, 401, <String, dynamic>{'error': 'unauthorized'}),
      phone: const Size(360, 760), wide: const Size(1280, 800)),
  _Case('direct_locked', (t) => _direct(t, 423, <String, dynamic>{'error': 'locked', 'retry_after': 60}),
      phone: const Size(360, 760), wide: const Size(1280, 800)),
];

/// Panoyu kurar. Yüzey önce [size] yüksekliğinin üstünde (uzun içerik sığsın diye en az 4500 dp) açılır, içerik
/// ölçülür ve yüzey içeriğe küçültülür: [fit] `true` ise tam içerik boyuna, değilse en az [size] yüksekliğine
/// (sabit yükseklik varsayımı alt kartı kırpıyordu; eleştirmen bulgusu: harness-artifact).
///
/// Yakalama sınırı Navigator'ı KAPSAR ([galleryAppBuilder]): pano üstünden açılan snackbar / diyalog / alt sayfa (modal
/// perde dahil) PNG'ye girer. [realBackground]: üretimdeki GERÇEK PCB fotoğraflı zemin (arka planda doğrudan duran
/// metinlerin kontrastı üretimle birebir değerlendirilir); varsayılan düşük kontrastlı vektör zemin.
Future<void> _pumpDashboard(
  WidgetTester tester,
  AutomationState state, {
  required GlobalKey boundaryKey,
  required Brightness brightness,
  required double textScale,
  required Size size,
  required double dpr,
  bool fit = false,
  bool realBackground = false,
}) async {
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = Size(size.width * dpr, (size.height < 4500 ? 4500 : size.height) * dpr);
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
          builder: galleryAppBuilder(boundaryKey: boundaryKey, textScale: textScale, realBackground: realBackground),
          home: const DashboardPage(),
        ),
      ),
    ),
  );
  // Üst çubuk logosu (ve gerçek zemin görselleri) soğuk görsel önbelleğinde birkaç karede çözülmeyebilir (çalışmanın ilk
  // PNG'sinde boş halka kalırdı): varlıklar gerçek asenkron bölgede önceden yüklenir.
  await precacheGalleryImages(tester, backgrounds: realBackground);
  await tester.pump();
  // Kademeli giriş (en çok 8 öğe x 40 ms + 220 ms) ve nabızlar bitsin.
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }

  // Yüzeyi içeriğe göre kırp: Scaffold gövdesi gevşek kısıt alır, dikey kaydırma görünümü içeriğine büzüşür
  // (görünüm yüksekliği = içerik + 12 üst + 30 alt dolgu); toplam = üst çubuk + kaydırma görünümü.
  final appBar = tester.getSize(find.byType(DashboardAppBar)).height;
  final viewport = tester.getSize(find.byKey(const Key('view_apartment'))).height;
  final measured = appBar + viewport;
  final target = fit ? measured : (measured > size.height ? measured : size.height);
  tester.view.physicalSize = Size(size.width * dpr, target * dpr);
  await tester.pump(const Duration(milliseconds: 100));
}

/// Gerçek (fotoğraflı) zeminle ayrıca çekilen durumlar: bölüm başlıkları / alt yazılar gibi zeminde DOĞRUDAN duran
/// metinler üretimdeki zeminde değerlendirilsin (dosya adı `<durum>_phone_<tema>_1.0_real.png`). Yalnız telefon 1.0 (dosya
/// boyutunu sınırlamak için).
const Set<String> _realBackgroundCases = <String>{'content_lit', 'homeless', 'loading'};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Pano galerisi', skip: visualSkipReason, () {
    setUpAll(loadGoldenFonts);

    for (final c in _cases) {
      // (cihaz, parlaklık, ölçek) birleşimleri: telefon 4'lü; tablet/masaüstü yalnız ölçek 1.0.
      final variants = <({String device, Brightness b, double scale, bool wide, Size? size, bool real})>[
        for (final b in [Brightness.dark, Brightness.light])
          for (final scale in [1.0, 1.5]) (device: 'phone', b: b, scale: scale, wide: false, size: null, real: false),
        for (final b in [Brightness.dark, Brightness.light])
          (device: 'tablet', b: b, scale: 1.0, wide: true, size: const Size(800, 1280), real: false),
        for (final b in [Brightness.dark, Brightness.light]) (device: 'desktop', b: b, scale: 1.0, wide: true, size: null, real: false),
        if (_realBackgroundCases.contains(c.name))
          for (final b in [Brightness.dark, Brightness.light]) (device: 'phone', b: b, scale: 1.0, wide: false, size: null, real: true),
      ];
      for (final v in variants) {
        final tag = '${c.name}_${v.device}_${v.b.name}_${v.scale}${v.real ? '_real' : ''}';
        testWidgets('pano: $tag', (tester) async {
          final h = await c.setup(tester);
          final key = GlobalKey();
          final size = v.size ?? (v.device == 'phone' ? c.phone : c.wide);
          await _pumpDashboard(
            tester,
            h.state,
            boundaryKey: key,
            brightness: v.b,
            textScale: v.scale,
            size: size,
            dpr: 2,
            fit: c.fit,
            realBackground: v.real,
          );
          expect(tester.takeException(), isNull, reason: tag);
          await expectGolden(tester, key, '$tag.png', pixelRatio: v.scale > 1 ? 1.0 : 1.5);
        });
      }
    }
  });
}
