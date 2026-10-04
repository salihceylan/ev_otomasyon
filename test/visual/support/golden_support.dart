// Görsel (golden) galeri destek kodu: GERÇEK yazı tipi (Roboto) ve MaterialIcons yüklü render.
//
// Ahem kutuları YOK: Flutter SDK'daki `bin/cache/artifacts/material_fonts` altındaki Roboto ve
// MaterialIcons dosyaları `FontLoader` ile yüklenir (ağ/`google_fonts` gerekmez). Tema yazı tipi,
// `AppTheme`'in Inter adları bu galeride Roboto dosyalarına bağlanır (uygulama koduna dokunulmaz).
// Sabit aralıklı ('monospace') ve bilinen diğer aile adları da Roboto'ya bağlanır: UUID/MAC/PIN metinleri Ahem
// bloğu yerine gerçek glifle çizilir.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ev_otomasyon/ui/motion/ambient_clock.dart';
import 'package:ev_otomasyon/ui/motion/motion_scope.dart';
import 'package:ev_otomasyon/ui/theme/app_theme.dart';
import 'package:ev_otomasyon/ui/widgets/circuit_background.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

/// Galeri varsayılan koşuda ATLANIR; yalnız `flutter test --tags visual --update-goldens` (PNG üretir) ya da
/// `AHBU_VISUAL=1 flutter test --tags visual` (kayıtlı PNG ile karşılaştırır) ile çalışır.
final String? visualSkipReason = (autoUpdateGoldenFiles || Platform.environment['AHBU_VISUAL'] == '1')
    ? null
    : 'Görsel galeri: `flutter test --tags visual --update-goldens` ile çalıştırın';

String _flutterRoot() {
  final env = Platform.environment['FLUTTER_ROOT'];
  if (env != null && Directory('$env/bin/cache/artifacts/material_fonts').existsSync()) return env;
  var dir = File(Platform.resolvedExecutable).parent;
  for (var i = 0; i < 10; i++) {
    if (Directory('${dir.path}/bin/cache/artifacts/material_fonts').existsSync()) return dir.path;
    dir = dir.parent;
  }
  throw StateError('Flutter SDK yazı tipleri bulunamadı (FLUTTER_ROOT ayarlayın)');
}

bool _fontsLoaded = false;

/// Roboto (400/500/700/900) ve MaterialIcons'u yükler. `setUpAll` içinde çağrılmalıdır (gerçek async).
Future<void> loadGoldenFonts() async {
  if (_fontsLoaded) return;
  GoogleFonts.config.allowRuntimeFetching = false;
  final dir = '${_flutterRoot()}/bin/cache/artifacts/material_fonts';
  Future<ByteData> read(String name) async {
    final bytes = await File('$dir/$name').readAsBytes();
    return ByteData.view(Uint8List.fromList(bytes).buffer);
  }

  // `AppTheme` metni Inter ailesiyle (google_fonts adları: 'Inter_regular', 'Inter_500', ...) ister. Testte
  // Inter yok: aynı adlar Roboto dosyalarına bağlanır, böylece tema stilleri DOĞRUDAN (yedek aile olmadan) gerçek
  // glif çizer. Roboto'da 600 yok: 600→bold, 800/900→black.
  const weights = <String, String>{
    'regular': 'roboto-regular.ttf',
    '100': 'roboto-regular.ttf',
    '200': 'roboto-regular.ttf',
    '300': 'roboto-regular.ttf',
    '500': 'roboto-medium.ttf',
    '600': 'roboto-bold.ttf',
    '700': 'roboto-bold.ttf',
    '800': 'roboto-black.ttf',
    '900': 'roboto-black.ttf',
  };
  // 'monospace': uygulamada UUID/MAC/PIN için kullanılan sabit aralıklı aile adı. Testte tanımsız olduğundan Ahem
  // (içi dolu blok) çıkardı; gerçek cihazda platform mono yazı tipine düşer. Burada Roboto'ya bağlanır (genişlikler
  // gerçek mono'dan biraz farklıdır, ama okunur glif çizilir ve satır kırılması makuldür).
  for (final family in ['Roboto', 'Inter', 'monospace']) {
    final loader = FontLoader(family)
      ..addFont(read('roboto-regular.ttf'))
      ..addFont(read('roboto-medium.ttf'))
      ..addFont(read('roboto-bold.ttf'))
      ..addFont(read('roboto-black.ttf'));
    await loader.load();
  }
  for (final entry in weights.entries) {
    final loader = FontLoader('Inter_${entry.key}')..addFont(read(entry.value));
    await loader.load();
  }
  final icons = FontLoader('MaterialIcons')..addFont(read('materialicons-regular.otf'));
  await icons.load();
  _fontsLoaded = true;
}

/// Uygulama temasını (Inter adları Roboto dosyalarına bağlı) döndürür.
ThemeData goldenTheme(Brightness brightness) {
  // `AppTheme`, `GoogleFonts.interTextTheme` ile Inter'i ASENKRON yüklemeye çalışır; testte (ağ yok, yazı tipi
  // varlığı yok) bu yükleme hata atar ve gerçek-async bekleyen golden karşılaştırmasında testi düşürür.
  // Tema, hatayı yutan ayrı bir bölgede kurulur; Inter adları `loadGoldenFonts` ile Roboto'ya bağlıdır.
  // (AppBar/diyalog başlıkları artık temada Inter ailesini taşır: eski "başlıkları Roboto'ya bağla" yaması gerekmez.)
  return runZonedGuarded<ThemeData>(
    () => brightness == Brightness.dark ? AppTheme.darkTheme : AppTheme.lightTheme,
    (Object error, StackTrace stack) {},
  )!;
}

/// Galeri gövdesi: uygulama zemini + devre izleri (cam/parıltı gerçekçi zeminde değerlendirilsin).
///
/// [realBackground] `true` ise üretimdeki GERÇEK [CircuitBackground] (PCB fotoğrafı + üst gradyan + vektör iz + veri
/// nabzı) kullanılır: arka planda doğrudan duran metinlerin (AppBar başlığı, bölüm başlıkları, boş-durum yazıları)
/// kontrastı üretimle birebir değerlendirilir. Varsayılan `false` (eski davranış: düşük kontrastlı vektör zemin).
/// Gerçek zemin görüntüleri `pumpGallery` içinde önceden çözülür (`precacheImage`); kendi harness'ini kuran testler
/// [precacheGalleryImages] çağırmalıdır.
class GalleryBackdrop extends StatelessWidget {
  const GalleryBackdrop({super.key, required this.child, this.realBackground = false});

  final Widget child;
  final bool realBackground;

  @override
  Widget build(BuildContext context) {
    if (realBackground) return CircuitBackground(child: child);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: dark
                    ? const [Color(0xFF0B1120), Color(0xFF0E1830), Color(0xFF0B1120)]
                    : const [Color(0xFFF8FAFC), Color(0xFFEFF4FA), Color(0xFFF8FAFC)],
              ),
            ),
          ),
        ),
        Positioned.fill(child: CustomPaint(painter: CircuitBoardPainter(isDark: dark))),
        Material(type: MaterialType.transparency, child: child),
      ],
    );
  }
}

/// Sayfayı bir kök sayfanın ÜSTÜNE yığar: gerçek akışta ikincil sayfalar `Navigator.push` ile açılır ve `NeonAppBar`'da geri
/// diski görünür; `home` olarak kurulan sayfa KÖK rotadır ve geri düğmesi çizmez. İç `Navigator` iki başlangıç rotası alır
/// (boş kök + sayfa): geçiş animasyonu yoktur, yakalama sınırı ([galleryAppBuilder]) içindedir. Sayfa, kapsayan
/// sağlayıcıları/temayı aynen miras alır.
class PushedOverHome extends StatelessWidget {
  const PushedOverHome({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Navigator(
    onGenerateInitialRoutes: (navigator, initialRoute) => <Route<dynamic>>[
      MaterialPageRoute<void>(builder: (_) => const Scaffold(backgroundColor: Colors.transparent)),
      MaterialPageRoute<void>(builder: (_) => child),
    ],
  );
}

/// Galeride kullanılan görseller (AppBar logoları + gerçek arka plan JPEG'leri).
const List<String> galleryLogoAssets = <String>['assets/images/app_logo.png', 'assets/images/round_app_logo.png'];
const List<String> galleryBackgroundAssets = <String>['assets/images/ai_circuit_bg.jpg', 'assets/images/ai_circuit_bg_light.jpg'];

/// Görselleri GERÇEK async ile önceden çözer: `Image.asset` ilk karede çözülmemiş olursa (soğuk `ImageCache`; çalışmanın
/// İLK golden'ı) logo/arka plan boş çıkardı. Eksik/okunamayan görsel testi düşürmez. Çağrıdan sonra `pump()` gerekir.
Future<void> precacheGalleryImages(WidgetTester tester, {bool backgrounds = false}) async {
  final context = tester.element(find.byType(MaterialApp));
  await tester.runAsync(() async {
    for (final asset in [...galleryLogoAssets, if (backgrounds) ...galleryBackgroundAssets]) {
      await precacheImage(AssetImage(asset), context, onError: (Object error, StackTrace? stack) {});
    }
  });
}

/// `MaterialApp.builder` için galeri sarmalayıcısı: yazı ölçeği + yakalama sınırı ([boundaryKey]) + zemin ([GalleryBackdrop]).
///
/// Sınır Navigator'ı KAPSAR: `showDialog`/`showModalBottomSheet`/Overlay rotaları (modal perde dahil) PNG'ye girer.
/// `pumpGallery` bunu kullanır; kendi `MaterialApp`ını kuran galeriler (Provider/durum kuran ekran galerileri) aynı
/// düzeni `builder: galleryAppBuilder(boundaryKey: key, textScale: scale)` ve `home: <ekran>` ile alır (eski düzen
/// `home: RepaintBoundary(key, child: GalleryBackdrop(child: ekran))` diyalogları yakalamıyordu). [realBackground] için
/// bkz. [GalleryBackdrop]; gerçek zemin görselleri için `precacheGalleryImages(tester, backgrounds: true)` çağırın.
TransitionBuilder galleryAppBuilder({
  required GlobalKey boundaryKey,
  required double textScale,
  bool realBackground = false,
}) {
  return (context, navigator) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: RepaintBoundary(
          key: boundaryKey,
          child: GalleryBackdrop(realBackground: realBackground, child: navigator!),
        ),
      );
}

/// Galeri sayfasını kurar: MotionScope(full) + sabit AmbientClock (deterministik), seçili tema ve yazı ölçeği.
///
/// **Yakalama sınırı Navigator'ı KAPSAR** (`MaterialApp.builder` içinde `RepaintBoundary(boundaryKey)`): `showDialog`,
/// `showModalBottomSheet`, `Overlay`/rota ile eklenen her şey (modal PERDESİ dahil) PNG'ye girer. Eski düzende sınır
/// `home` altındaydı ve bu rotalar sınırın dışında kalıp görünmüyordu. Zemin ([GalleryBackdrop]) de Navigator'ın
/// ALTINDADIR (üretimdeki `CircuitBackground` gibi): rota değiştikçe/perde açıldıkça zemin yerinde kalır.
///
/// Geriye uyumluluk: [child] eskisi gibi şeffaf bir `Material` içinde, sol-üstte ve GEVŞEK kısıtla yerleşir.
/// Diyalog/alt sayfa açan galeri, [child] içinden (bir `Navigator` altındaki bağlamla) `showDialog` vb. çağırır.
/// [realBackground] için bkz. [GalleryBackdrop].
///
/// [fitHeight] `true` ise yüzey yüksekliği İÇERİĞİN yüksekliğine eşitlenir ([size].height üst sınırdır): PNG ne içerik
/// keser ne de altta boş bant bırakır (yazı ölçeği 1.5/2.0'da sabit yükseklik içeriği kesiyordu). Bunun için [child]
/// kendi kendini ölçmeli ( `Column(mainAxisSize: min)` gibi); kaydırma görünümü içine sarılmış içerik ölçülemez
/// (görünüm tüm yüksekliği doldurur).
Future<void> pumpGallery(
  WidgetTester tester, {
  required GlobalKey boundaryKey,
  required Brightness brightness,
  required double textScale,
  required Size size,
  required Widget child,
  double clockSeconds = 0.65,
  bool realBackground = false,
  bool fitHeight = false,
}) async {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = Size(size.width * 2, size.height * 2);
  addTearDown(tester.view.reset);

  final fitKey = GlobalKey();
  final clock = AmbientClock.fixed(clockSeconds);
  addTearDown(clock.dispose);
  await tester.pumpWidget(
    MotionScope(
      mode: MotionMode.full,
      clock: clock,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: goldenTheme(Brightness.light),
        darkTheme: goldenTheme(Brightness.dark),
        themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
        builder: galleryAppBuilder(boundaryKey: boundaryKey, textScale: textScale, realBackground: realBackground),
        home: Align(
          alignment: AlignmentDirectional.topStart,
          child: Material(type: MaterialType.transparency, child: fitHeight ? KeyedSubtree(key: fitKey, child: child) : child),
        ),
      ),
    ),
  );
  await precacheGalleryImages(tester, backgrounds: realBackground);
  await tester.pump();
  if (fitHeight) {
    final content = tester.getSize(find.byKey(fitKey));
    tester.view.physicalSize = Size(size.width * 2, content.height.ceilToDouble() * 2);
    await tester.pump();
  }
}

/// flutter_test'in otomatik bağlaması testler boyunca gölgeleri kapatır (`debugDisableShadows = true`; değişmezlik
/// denetimi test sonunda bu değeri bekler). Capture için geçici olarak açılır, sonra bu değere geri alınır.
const bool _testBindingDisablesShadows = true;

void _markNeedsPaintDeep(RenderObject node) {
  node.markNeedsPaint();
  node.visitChildren(_markNeedsPaintDeep);
}

/// [boundaryKey] sınırını [pixelRatio] ile PNG'ye çevirir ve `test/visual/goldens/<name>` ile eşler:
/// `--update-goldens` ile dosyayı yazar, aksi halde kayıtlı dosyayla piksel karşılaştırır.
///
/// Gölge: flutter_test gölgeleri sert bloklara çevirir (BoxShadow bulanıklığı kapanır, Material yükseltmesi düz
/// halka olur). İncelenecek PNG'de yumuşak gölge/parıltı görünsün diye HER capture öncesi gölgeler açılır ve sınır
/// içeriği yeniden boyanır; capture sonrası eski değere dönülür. (Tek test içinde birden çok `expectGolden`
/// çağrısında ya da `pumpGallery` kullanmayan testlerde de gölgeler yumuşaktır.)
Future<void> expectGolden(
  WidgetTester tester,
  GlobalKey boundaryKey,
  String name, {
  double pixelRatio = 2,
}) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(boundaryKey));
  final Uint8List bytes;
  try {
    // Başka bir harness gölgeyi kendisi açmış olabilir: yalnız kapalıyken yeniden boya.
    if (debugDisableShadows) {
      debugDisableShadows = false;
      _markNeedsPaintDeep(boundary);
      await tester.pump();
    }
    bytes = (await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: pixelRatio);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return data!.buffer.asUint8List();
    }))!;
  } finally {
    // (Değişken test sonunda geri alınır: flutter_test değişmezlik denetimi tearDown'dan ÖNCE çalışır.)
    debugDisableShadows = _testBindingDisablesShadows;
  }
  final uri = Uri.parse('goldens/$name');
  if (autoUpdateGoldenFiles) {
    await tester.runAsync(() => goldenFileComparator.update(uri, bytes));
  } else {
    final ok = await tester.runAsync(() => goldenFileComparator.compare(bytes, uri));
    expect(ok, isTrue, reason: '$name kayıtlı PNG ile eşleşmiyor');
  }
}
