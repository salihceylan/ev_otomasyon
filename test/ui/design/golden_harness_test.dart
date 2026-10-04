import 'dart:async';

import 'package:ev_otomasyon/ui/widgets/circuit_background.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../visual/support/golden_support.dart';

/// Görsel galeri harness'i (`test/visual/support/golden_support.dart`) sözleşmeleri. Golden galerileri varsayılan koşuda
/// ATLANDIĞINDAN harness hataları sessiz kalırdı: kritik davranışlar (yakalama sınırı Navigator'ı kapsar, gölge/yazı
/// tipi/görsel ısıtma, içeriğe sığan yükseklik) burada varsayılan koşuda denetlenir.
void main() {
  setUpAll(loadGoldenFonts);

  Future<BuildContext> pumpProbe(
    WidgetTester tester, {
    required GlobalKey key,
    bool realBackground = false,
    bool fitHeight = false,
    Size size = const Size(360, 640),
    Widget? content,
  }) async {
    late BuildContext captured;
    await pumpGallery(
      tester,
      boundaryKey: key,
      brightness: Brightness.dark,
      textScale: 1.0,
      size: size,
      realBackground: realBackground,
      fitHeight: fitHeight,
      child: Builder(builder: (context) {
        captured = context;
        return content ?? const SizedBox(key: Key('probe'), width: 100, height: 100);
      }),
    );
    return captured;
  }

  testWidgets('yakalama sınırı Navigator\'ı KAPSAR: showDialog / showModalBottomSheet rotaları (perde dahil) sınırın içinde', (tester) async {
    final key = GlobalKey();
    final context = await pumpProbe(tester, key: key);
    final boundary = find.byKey(key);
    expect(find.descendant(of: boundary, matching: find.byType(Navigator)), findsOneWidget);

    unawaited(showDialog<void>(context: context, builder: (_) => const AlertDialog(title: Text('Başlık'), content: Text('İçerik'))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.descendant(of: boundary, matching: find.byType(AlertDialog)), findsOneWidget, reason: 'diyalog PNG sınırının içinde');
    expect(find.descendant(of: boundary, matching: find.byType(ModalBarrier)), findsWidgets, reason: 'modal perde de sınırın içinde');
    Navigator.of(tester.element(find.byType(AlertDialog))).pop();
    await tester.pumpAndSettle();

    unawaited(showModalBottomSheet<void>(context: context, builder: (_) => const SizedBox(height: 120, child: Text('Sayfa'))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.descendant(of: boundary, matching: find.text('Sayfa')), findsOneWidget, reason: 'alt sayfa PNG sınırının içinde');
    expect(tester.takeException(), isNull);
  });

  testWidgets('galleryAppBuilder: kendi MaterialApp kuran galeriler de diyalog/perdeyi yakalar (home: ekran, sınır builder içinde)', (tester) async {
    final key = GlobalKey();
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        theme: goldenTheme(Brightness.light),
        builder: galleryAppBuilder(boundaryKey: key, textScale: 1.5),
        home: Scaffold(body: Builder(builder: (c) {
          context = c;
          return const Text('ekran', key: Key('screen'));
        })),
      ),
    );
    expect(MediaQuery.textScalerOf(context).scale(10), 15, reason: 'yazı ölçeği builder üzerinden gelir');
    unawaited(showDialog<void>(context: context, builder: (_) => const AlertDialog(content: Text('diyalog'))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.descendant(of: find.byKey(key), matching: find.text('diyalog')), findsOneWidget);
    expect(find.descendant(of: find.byKey(key), matching: find.byKey(const Key('screen'))), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('geriye uyum: child şeffaf Material içinde, sol-üstte ve GEVŞEK kısıtla yerleşir (eski galeri çağrıları aynen çalışır)', (tester) async {
    final key = GlobalKey();
    await pumpProbe(tester, key: key);
    expect(tester.getTopLeft(find.byKey(const Key('probe'))), Offset.zero);
    expect(tester.getSize(find.byKey(const Key('probe'))), const Size(100, 100));
    expect(find.ancestor(of: find.byKey(const Key('probe')), matching: find.byType(Material)), findsWidgets, reason: 'InkWell/Slider için Material atası');
    expect(tester.getSize(find.byKey(key)), const Size(360, 640), reason: 'sınır tüm yüzeyi kaplar');
  });

  testWidgets('pumpGallery gölge bayrağını DEĞİŞTİRMEZ (gölge yalnız capture sırasında açılır; test sonu değişmezlik denetimi)', (tester) async {
    final key = GlobalKey();
    final before = debugDisableShadows;
    await pumpProbe(tester, key: key);
    expect(debugDisableShadows, before);
    expect(before, isTrue, reason: 'flutter_test testler boyunca gölgeleri kapatır');
  });

  testWidgets('fitHeight: yüzey yüksekliği içeriğe eşitlenir (üst sınır size.height)', (tester) async {
    final key = GlobalKey();
    await pumpProbe(
      tester,
      key: key,
      fitHeight: true,
      size: const Size(360, 4000),
      content: const Column(mainAxisSize: MainAxisSize.min, children: [SizedBox(key: Key('probe'), width: 100, height: 300), SizedBox(width: 100, height: 55.2)]),
    );
    // 355.2 dp → yukarı yuvarlanır (356) → DPR 2 ile 712 fiziksel piksel.
    expect(tester.view.physicalSize.height, 712);
    expect(tester.getSize(find.byKey(key)).height, 356);
    expect(tester.takeException(), isNull);
  });

  testWidgets('GalleryBackdrop: varsayılan vektör zemin (eski davranış); realBackground:true gerçek CircuitBackground', (tester) async {
    final plainKey = GlobalKey();
    await pumpProbe(tester, key: plainKey);
    expect(find.byType(CircuitBackground), findsNothing);
    expect(find.descendant(of: find.byKey(plainKey), matching: find.byType(CustomPaint)), findsWidgets);

    final realKey = GlobalKey();
    await pumpProbe(tester, key: realKey, realBackground: true);
    expect(find.descendant(of: find.byKey(realKey), matching: find.byType(CircuitBackground)), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ısıtma: logolar (ve gerçek zeminde arka plan görselleri) ImageCache\'e alınır — ilk golden boş logo çıkmaz', (tester) async {
    imageCache.clear();
    imageCache.clearLiveImages();
    expect(imageCache.currentSize, 0);
    final key = GlobalKey();
    await pumpProbe(tester, key: key, realBackground: true);
    expect(imageCache.currentSize, greaterThanOrEqualTo(galleryLogoAssets.length + galleryBackgroundAssets.length),
        reason: 'logo + arka plan görselleri çözülmüş ve önbellekte');
  });

  test('"monospace" ailesi Roboto\'ya bağlanır: Ahem bloğu (her glif eş genişlik) yerine orantılı gerçek glif', () {
    double width(String text) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: const TextStyle(fontFamily: 'monospace', fontSize: 20)),
        textDirection: TextDirection.ltr,
      )..layout();
      final w = painter.width;
      painter.dispose();
      return w;
    }

    // Ahem'de her glif 1 em genişliğindedir: 'iiii' ile 'WWWW' aynı olurdu. Roboto'da 'i' çok dardır.
    expect(width('iiii'), lessThan(width('WWWW') - 10));
  });
}
