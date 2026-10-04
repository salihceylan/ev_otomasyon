import 'dart:async';

import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/auth/auth_gate.dart';
import 'package:ev_otomasyon/ui/pages/auth/login_page.dart';
import 'package:ev_otomasyon/ui/widgets/circuit_background.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';
import 'e1_helpers.dart';

/// Açılış / giriş / devre arka planı **çizim katmanları** ve açılış ekranının yeniden kurulumu
/// (WP-BOOT: PF-37, PF-15 a, PF-21, PF-12 kalıntısı).
///
/// Kanıt bir ölçüm DEĞİL, **sayaçtır**: `debugOnProfilePaint` bir render nesnesinin üst nesnesi
/// tarafından kaç kez boyandığını, `debugOnRebuildDirtyWidget` bir widget'ın kaç kez yeniden kurulduğunu
/// sayar (yalnız debug derlemede çalışır; testler debug'da çalışır). Temiz bir `RepaintBoundary`'nin
/// içindeki nesneler yeniden boyanmaz ve sayılmaz: sayaç 0 ise o katman o karede yeniden kaydedilmemiştir.
/// Süre / kare hızı / pil iddiası YOKTUR (cihazda ölçülmedi).
///
/// Not: açılış içeriği bir `SingleChildScrollView` içindedir ve onun viewport'u zaten bir yeniden-çizim
/// sınırıdır. Bu yüzden sınırsız gösterge JPEG'i değil, o viewport katmanını (logo halkası + iki büyük
/// bulanık gölge, metin gölgeli başlık, panel gölgesi) her karede yeniden boyatır; düzeltme göstergeyi o
/// katmandan ayırır.
void main() {
  const bgAsset = 'assets/images/ai_circuit_bg.jpg';

  group('Açılış ekranı çizim katmanları (PF-37)', () {
    testWidgets('dönen gösterge kendi yeniden-çizim sınırındadır; statik arka plan ve sayfa içeriği ondan ayrı katmandadır',
        (tester) async {
      final h = StateHarness();
      addTearDown(h.dispose);
      h.state.setAuthStatusForTesting(AuthStatus.checking);
      await pumpPage(tester, h.state, const AuthGate(), size: const Size(540, 1200));

      final spinnerBoundary = _boundaryOf(tester.renderObject(find.byType(CircularProgressIndicator)));
      final titleNode = tester.renderObject(find.text('AHBU OTOMASYON'));
      final titleBoundary = _boundaryOf(titleNode);
      expect(spinnerBoundary, isNotNull);
      expect(titleBoundary, isNotNull);
      expect(spinnerBoundary, isNot(same(titleBoundary)),
          reason: 'gösterge ile marka başlığı aynı sınırı paylaşırsa gösterge her karede tüm sayfayı yeniden boyatır');
      expect(_boundariesAbove(titleNode), isNot(contains(spinnerBoundary)), reason: 'sayfa içeriği göstergenin sınırının altında değil');

      final imageBoundary = _boundaryOf(tester.renderObject(_rawImageOf(_assetImage(bgAsset))));
      final gradientBoundary = _boundaryOf(tester.renderObject(_gradientBox()));
      expect(imageBoundary, same(gradientBoundary), reason: 'arka plan JPEG\'i ve gradyanı TEK sınırda');
      expect(_boundariesAbove(titleNode), isNot(contains(imageBoundary)), reason: 'statik arka plan sınırı sayfa içeriğini kapsamaz');
    });

    testWidgets('gösterge her karede dönerken logo halkası (büyük gölgeler), başlık, panel, arka plan resmi ve gradyan yeniden BOYANMAZ',
        (tester) async {
      final h = StateHarness();
      addTearDown(h.dispose);
      h.state.setAuthStatusForTesting(AuthStatus.checking);
      await pumpPage(tester, h.state, const AuthGate(), size: const Size(540, 1200));

      final spinner = tester.renderObject(find.descendant(of: find.byType(CircularProgressIndicator), matching: find.byType(CustomPaint)).first);
      final ring = tester.renderObject(_shadowBox(2)); // logo halkası: iki büyük bulanık gölge (36/60 px)
      final panel = tester.renderObject(_shadowBox(1)); // doğrulama paneli gölgesi
      final title = tester.renderObject(find.text('AHBU OTOMASYON')); // metin gölgeli başlık
      final backdropImage = tester.renderObject(_rawImageOf(_assetImage(bgAsset)));
      final backdropGradient = tester.renderObject(_gradientBox());

      final probe = _PaintProbe(<RenderObject>[spinner, ring, panel, title, backdropImage, backdropGradient]);
      await probe.record(() async {
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      });

      expect(probe.countOf(spinner), greaterThanOrEqualTo(8), reason: 'pozitif kontrol: sayaç gerçek spinner karelerini görüyor');
      expect(probe.countOf(ring), 0, reason: 'logo halkası (iki büyük bulanık gölge) spinner karelerinde yeniden boyanmamalı');
      expect(probe.countOf(panel), 0, reason: 'panel (gölgeli) spinner karelerinde yeniden boyanmamalı');
      expect(probe.countOf(title), 0, reason: 'marka başlığı (metin gölgeli) spinner karelerinde yeniden boyanmamalı');
      expect(probe.countOf(backdropImage), 0, reason: 'arka plan JPEG\'i spinner karelerinde yeniden boyanmamalı');
      expect(probe.countOf(backdropGradient), 0, reason: 'arka plan gradyanı spinner karelerinde yeniden boyanmamalı');
    });
  });

  group('CircuitBackground katmanları (PF-15 a)', () {
    Future<void> pumpBackground(WidgetTester tester, Widget child) {
      return tester.pumpWidget(MaterialApp(home: Scaffold(body: CircuitBackground(child: child))));
    }

    testWidgets('düz renk + JPEG + gradyan TEK sınırda, PCB çizici ayrı sınırda; içerik statik sınırın altında değil', (tester) async {
      await pumpBackground(tester, const Center(child: Text('içerik')));

      final boundaries = find.descendant(of: find.byType(CircuitBackground), matching: find.byType(RepaintBoundary));
      expect(boundaries.evaluate().length, greaterThanOrEqualTo(2), reason: 'statik katmanlar + PCB çizici');

      final base = _boundaryOf(tester.renderObject(find.descendant(of: find.byType(CircuitBackground), matching: find.byType(ColoredBox))));
      final image = _boundaryOf(tester.renderObject(find.descendant(of: find.byType(CircuitBackground), matching: find.byType(RawImage))));
      final gradient =
          _boundaryOf(tester.renderObject(find.descendant(of: find.byType(CircuitBackground), matching: _gradientBox())));
      final painter = _boundaryOf(
        tester.renderObject(
          find.descendant(
            of: find.byType(CircuitBackground),
            matching: find.byWidgetPredicate((w) => w is CustomPaint && w.painter is CircuitBoardPainter),
          ),
        ),
      );
      expect(base, same(image), reason: 'düz renk zemin ve JPEG aynı sınırda');
      expect(image, same(gradient), reason: 'JPEG ve gradyan aynı sınırda');
      expect(painter, isNot(same(image)), reason: 'PCB çizici kendi sınırında');
      expect(_boundariesAbove(tester.renderObject(find.text('içerik'))), isNot(contains(image)),
          reason: 'sayfa içeriği statik katman sınırının altında değil (kardeş)');
    });

    testWidgets('çocuk her karede boyanırken düz renk, JPEG ve gradyan yeniden BOYANMAZ', (tester) async {
      await pumpBackground(tester, const Center(child: CircularProgressIndicator()));
      await tester.pump();

      final inBackground = find.byType(CircuitBackground);
      final spinner = tester.renderObject(find.descendant(of: find.byType(CircularProgressIndicator), matching: find.byType(CustomPaint)).first);
      final base = tester.renderObject(find.descendant(of: inBackground, matching: find.byType(ColoredBox)));
      final image = tester.renderObject(find.descendant(of: inBackground, matching: find.byType(RawImage)));
      final gradient = tester.renderObject(find.descendant(of: inBackground, matching: _gradientBox()));

      final probe = _PaintProbe(<RenderObject>[spinner, base, image, gradient]);
      await probe.record(() async {
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      });

      expect(probe.countOf(spinner), greaterThanOrEqualTo(8), reason: 'pozitif kontrol: sayaç gerçek spinner karelerini görüyor');
      expect(probe.countOf(base), 0, reason: 'düz renk zemin yeniden boyanmamalı');
      expect(probe.countOf(image), 0, reason: 'JPEG yeniden boyanmamalı');
      expect(probe.countOf(gradient), 0, reason: 'gradyan yeniden boyanmamalı');
    });
  });

  group('Arka plan resmi önbelleği (PF-15 b)', () {
    testWidgets('koyu temada küresel arka plan, açılış ve giriş aynı ImageProvider\'ı kullanır: tek ImageCache girdisi', (tester) async {
      Image imageOf(Finder finder) => tester.widget<Image>(finder.first);

      await tester.pumpWidget(
        MaterialApp(
          themeMode: ThemeMode.dark,
          darkTheme: ThemeData.dark(),
          home: const Scaffold(body: CircuitBackground(child: SizedBox())),
        ),
      );
      final global = imageOf(find.descendant(of: find.byType(CircuitBackground), matching: find.byType(Image))).image;

      final h = StateHarness();
      addTearDown(h.dispose);
      h.state.setAuthStatusForTesting(AuthStatus.checking);
      await pumpPage(tester, h.state, const AuthGate(), size: const Size(540, 1200));
      final splash = imageOf(_assetImage(bgAsset)).image;

      h.state.setAuthStatusForTesting(AuthStatus.unauthenticated);
      await pumpPage(tester, h.state, const LoginPage(), size: const Size(540, 1200));
      final login = imageOf(_assetImage(bgAsset)).image;

      expect(global, isA<AssetImage>());
      expect(global, splash, reason: 'farklı çözümleme boyutu/yol = ayrı ImageCache girdisi = JPEG iki kez çözülür');
      expect(global, login);
    });
  });

  group('Giriş ekranı arka planı (PF-15)', () {
    testWidgets('statik arka plan (JPEG + gradyan) tek sınırda ve form içeriğinden ayrı katmandadır', (tester) async {
      final h = StateHarness();
      addTearDown(h.dispose);
      h.state.setAuthStatusForTesting(AuthStatus.unauthenticated);
      await pumpPage(tester, h.state, const LoginPage(), size: const Size(540, 1200));

      final imageBoundary = _boundaryOf(tester.renderObject(_rawImageOf(_assetImage(bgAsset))));
      final gradientBoundary = _boundaryOf(tester.renderObject(_gradientBox()));
      expect(imageBoundary, isNotNull);
      expect(imageBoundary, same(gradientBoundary), reason: 'JPEG ve gradyan TEK sınırda');
      expect(_boundariesAbove(tester.renderObject(find.byKey(const Key('field_email')))), isNot(contains(imageBoundary)),
          reason: 'e-posta alanı (ve tüm form) statik arka plan sınırının altında değil');
      expect(_boundariesAbove(tester.renderObject(find.text('AHBU OTOMASYON'))), isNot(contains(imageBoundary)));
    });
  });

  group('Açılış ekranı yeniden kurulumu (PF-21)', () {
    testWidgets('ilgisiz durum bildirimlerinde yeniden kurulmaz; biyometrik değişimde kurulur', (tester) async {
      final h = StateHarness();
      addTearDown(h.dispose);
      h.state.setAuthStatusForTesting(AuthStatus.checking);
      await pumpPage(tester, h.state, const AuthGate(), size: const Size(540, 1200));
      expect(byKeyName('splash_checking'), findsOneWidget);

      final probe = _RebuildProbe('_AuthSplashScreen')..start();
      addTearDown(probe.stop);

      // Açılış ekranını ilgilendirmeyen bildirimler (tema, cihaz varlığı, mod).
      h.state.setThemeModeForTesting(ThemeMode.light);
      h.state.setPresenceForTesting(DevicePresence.online);
      h.state.setModeForTesting(AppMode.cloud);
      await tester.pump();
      expect(probe.count, 0, reason: 'splash yalnız biometricFailed / biometricChecking / biometricLabel için kurulur');
      expect(byKeyName('splash_checking'), findsOneWidget);

      // İlgili değişim: biyometrik doğrulama başarısız -> arayüz gerçekten güncellenir (pozitif kontrol).
      h.state.setBiometricForTesting(failed: true, label: 'Parmak İzi');
      await tester.pump();
      expect(probe.count, 1);
      expect(byKeyName('biometric_locked'), findsOneWidget);
      expect(find.text('Parmak İzi doğrulaması tamamlanamadı.'), findsOneWidget);

      // Aynı değerlerle yeni ilgisiz bildirim yine kurmaz.
      h.state.setPresenceForTesting(DevicePresence.offline);
      await tester.pump();
      expect(probe.count, 1);
    });

    testWidgets('select\'e geçişte eylemler çalışır: yeniden dene -> istem -> başarısızlık görünümü geri gelir', (tester) async {
      final h = StateHarness(biometricSupported: true);
      addTearDown(h.dispose);
      final prompt = Completer<bool>();
      h.biometric.pending = prompt; // istem açık kalsın: ara görünüm doğrulanabilsin
      h.state.setBiometricForTesting(isSupported: true, isEnabled: true, failed: true, label: 'Parmak İzi', authStatus: AuthStatus.checking);
      await pumpPage(tester, h.state, const AuthGate(), size: const Size(540, 1200));
      expect(byKeyName('biometric_locked'), findsOneWidget);

      await tester.tap(byKeyName('btn_biometric_retry'));
      await tester.pump();
      expect(h.biometric.authenticateCalls, 1, reason: 'düğme eylemi güncel durumu (context.read) kullanıp istemi başlattı');
      expect(byKeyName('splash_checking'), findsOneWidget, reason: 'istem sürerken "doğrulanıyor" görünümü');
      expect(byKeyName('biometric_locked'), findsNothing);

      prompt.complete(false);
      await tester.pump();
      await tester.pump();
      expect(byKeyName('biometric_locked'), findsOneWidget, reason: 'başarısız sonuç select ile arayüze yansır');
      expect(find.text('Parmak İzi doğrulaması tamamlanamadı.'), findsOneWidget);
    });
  });

  group('Kapı geçişi (PF-12 kalıntısı)', () {
    testWidgets('geçiş 250 ms ya da daha kısa: iki tam ekran daha uzun birlikte canlı tutulmaz', (tester) async {
      final h = StateHarness();
      addTearDown(h.dispose);
      h.state.setAuthStatusForTesting(AuthStatus.checking);
      await pumpPage(tester, h.state, const AuthGate(), size: const Size(540, 1200));

      final switcher = tester.widget<AnimatedSwitcher>(find.descendant(of: find.byType(AuthGate), matching: find.byType(AnimatedSwitcher)).first);
      expect(switcher.duration, lessThanOrEqualTo(const Duration(milliseconds: 250)));

      // Davranış: açılış -> giriş geçişi sürerken iki ekran birlikte canlıdır; 300 ms sonra yalnız giriş kalır.
      h.state.setAuthStatusForTesting(AuthStatus.unauthenticated);
      await tester.pump();
      expect(find.byKey(const ValueKey('splash_screen')), findsOneWidget, reason: 'geçiş sürerken çıkan açılış ekranı hâlâ ağaçta');
      expect(find.byType(LoginPage), findsOneWidget, reason: 'giren ekran birlikte canlı');
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('splash_screen')), findsNothing, reason: 'çıkan açılış ekranı 300 ms içinde ağaçtan kalkmış olmalı');
      expect(find.byType(LoginPage), findsOneWidget);
    });
  });
}

// =============================================================================
// Yardımcılar (yalnız bu dosyada; test/support WP-INFRA'nındır)
// =============================================================================

/// [node]'dan köke doğru ilk yeniden-çizim sınırı (kendisi sınırsa kendisi).
RenderObject? _boundaryOf(RenderObject node) {
  RenderObject? cursor = node;
  while (cursor != null && !cursor.isRepaintBoundary) {
    cursor = cursor.parent;
  }
  return cursor;
}

/// [node]'dan köke kadar tüm yeniden-çizim sınırları (kendisi sınırsa o da dahil).
Set<RenderObject> _boundariesAbove(RenderObject node) {
  final result = <RenderObject>{};
  RenderObject? cursor = node;
  while (cursor != null) {
    if (cursor.isRepaintBoundary) result.add(cursor);
    cursor = cursor.parent;
  }
  return result;
}

/// Verilen varlık yolunu gösteren `Image.asset` widget'ı.
Finder _assetImage(String asset) => find.byWidgetPredicate(
      (widget) => widget is Image && widget.image is AssetImage && (widget.image as AssetImage).assetName == asset,
    );

/// [image] widget'ının `RawImage`'i (render nesnesi `RenderImage`).
Finder _rawImageOf(Finder image) => find.descendant(of: image, matching: find.byType(RawImage));

/// Gradyanlı `DecoratedBox` (arka plan karartma katmanı).
/// Arka plan karartma gradyanı: üç duraklı `LinearGradient`. (Giriş formundaki camsı kartın iki renkli yüzey
/// gradyanı bundan ayrıdır: WP-V3 ile giriş formu `SurfaceCard` içinde.)
Finder _gradientBox() => find.byWidgetPredicate((widget) {
      if (widget is! DecoratedBox || widget.decoration is! BoxDecoration) return false;
      final gradient = (widget.decoration as BoxDecoration).gradient;
      return gradient is LinearGradient && gradient.colors.length == 3;
    });

/// Tam [count] gölgesi olan `DecoratedBox` (açılış ekranında: logo halkası 2, panel 1).
Finder _shadowBox(int count) => find.byWidgetPredicate(
      (widget) => widget is DecoratedBox && widget.decoration is BoxDecoration && ((widget.decoration as BoxDecoration).boxShadow?.length ?? 0) == count,
    );

/// İzlenen render nesnelerinin üst nesneleri tarafından kaç kez BOYANDIĞINI sayar (`debugOnProfilePaint`).
/// Temiz bir `RepaintBoundary`'nin içindeki nesneler için üst nesne boyama çağrısı yapmaz: sayaç artmaz.
class _PaintProbe {
  _PaintProbe(Iterable<RenderObject> watched) : _counts = <RenderObject, int>{for (final node in watched) node: 0};

  final Map<RenderObject, int> _counts;

  int countOf(RenderObject node) => _counts[node]!;

  Future<void> record(Future<void> Function() body) async {
    debugOnProfilePaint = (RenderObject node) {
      final count = _counts[node];
      if (count != null) _counts[node] = count + 1;
    };
    try {
      await body();
    } finally {
      debugOnProfilePaint = null; // test sonu "render değişkeni değişti" denetimi için şart
    }
  }
}

/// Belirli türdeki widget'ın yeniden kurulum sayısı (`debugOnRebuildDirtyWidget`; ilk kurulum da sayılır,
/// bu yüzden `start()` sayfa kurulduktan SONRA çağrılır).
class _RebuildProbe {
  _RebuildProbe(this.widgetTypeName);

  final String widgetTypeName;
  int count = 0;

  void start() {
    debugOnRebuildDirtyWidget = (Element element, bool builtOnce) {
      if (element.widget.runtimeType.toString() == widgetTypeName) count++;
    };
  }

  void stop() => debugOnRebuildDirtyWidget = null;
}
