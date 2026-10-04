@Tags(['visual'])
library;

// Neon Glass görsel galerisi (gerçek Roboto + MaterialIcons; Ahem YOK).
//
//   flutter test --tags visual --update-goldens test/visual     -> test/visual/goldens/*.png üretir
//   AHBU_VISUAL=1 flutter test --tags visual test/visual         -> kayıtlı PNG'lerle karşılaştırır
//
// Varsayılan `flutter test` koşusunda bu grup ATLANIR. Koyu + açık tema, yazı ölçeği 1.0 ve 1.5;
// MotionScope(full) + AmbientClock.fixed ile deterministik (nefes tepe noktasında dondurulur).
//
// Yüzey yüksekliği İÇERİĞE eşitlenir (`fitHeight`): PNG içerik kesmez, altta boş bant bırakmaz. Diyalog/alt sayfa
// galerileri GERÇEK `showDialog`/`showModalBottomSheet` açar: yakalama sınırı Navigator'ı kapsadığından modal perde de
// PNG'ye girer (`dialog_real_*`, `sheet_real_*`); `realbg_text_*` metni gerçek PCB fotoğrafı zemininde gösterir.

import 'dart:async';

import 'package:ev_otomasyon/ui/theme/tokens.dart';
import 'package:ev_otomasyon/ui/widgets/orb/orb.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/gallery_sheets.dart';
import 'support/golden_support.dart';

/// Yüzey yüksekliği üst sınırı (içeriğe göre kısaltılır).
const double _maxHeight = 4000;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Neon Glass galeri', () {
    setUpAll(loadGoldenFonts);

    for (final brightness in [Brightness.dark, Brightness.light]) {
      for (final scale in [1.0, 1.5]) {
        final tag = '${brightness.name}_$scale';
        // Dosya boyutunu küçük tutmak için 1.5 yazı ölçekli sayfalar 1×, 1.0 ölçekli sayfalar 2× PNG üretir
        // (1.5 ölçekli sayfaların amacı taşma/yerleşim denetimidir, parlaklık incelemesi değil).
        final ratio = scale > 1 ? 1.0 : 2.0;

        testWidgets('orb matrisi ($tag)', (tester) async {
          final key = GlobalKey();
          final status = ValueNotifier<OrbStatus>(OrbStatus.none);
          addTearDown(status.dispose);
          await pumpGallery(
            tester,
            boundaryKey: key,
            brightness: brightness,
            textScale: scale,
            size: const Size(580, _maxHeight),
            fitHeight: true,
            child: OrbMatrixSheet(status: status),
          );
          // Başarı halkası: ortasında yakala.
          status.value = OrbStatus.success;
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 140));
          // Basılı sütun: parmak değdiği an (gerçek dokunuşla).
          final gestures = <TestGesture>[];
          var pointer = 1;
          for (final v in orbVariants) {
            gestures.add(await tester.startGesture(tester.getCenter(find.byKey(pressedOrbKey(v.name))), pointer: pointer++));
          }
          await tester.pump();
          await expectGolden(tester, key, 'orbs_matrix_$tag.png', pixelRatio: ratio);
          for (final g in gestures) {
            await g.up();
          }
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        });

        testWidgets('bileşenler ($tag)', (tester) async {
          final key = GlobalKey();
          final toggle = ValueNotifier<bool>(false);
          final ring = ValueNotifier<int>(0);
          addTearDown(toggle.dispose);
          addTearDown(ring.dispose);
          await pumpGallery(
            tester,
            boundaryKey: key,
            brightness: brightness,
            textScale: scale,
            size: const Size(440, _maxHeight),
            fitHeight: true,
            child: ComponentsSheet(toggleValue: toggle, ringTrigger: ring),
          );
          toggle.value = true;
          ring.value = 1;
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 150));
          final g = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('glass_pressed'))));
          await tester.pump();
          await expectGolden(tester, key, 'components_$tag.png', pixelRatio: ratio);
          await g.up();
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        });

        testWidgets('kartlar ve kaydırıcılar ($tag)', (tester) async {
          final key = GlobalKey();
          final slider = ValueNotifier<double>(0.4);
          addTearDown(slider.dispose);
          await pumpGallery(
            tester,
            boundaryKey: key,
            brightness: brightness,
            textScale: scale,
            size: const Size(420, _maxHeight),
            fitHeight: true,
            child: CardsSheet(sliderValue: slider),
          );
          await tester.pump(const Duration(milliseconds: 400));
          await expectGolden(tester, key, 'cards_$tag.png', pixelRatio: ratio);
          expect(tester.takeException(), isNull);
        });

        testWidgets('diyalog, alt sayfa, snackbar, giriş alanı ($tag)', (tester) async {
          final key = GlobalKey();
          final focus = FocusNode();
          addTearDown(focus.dispose);
          await pumpGallery(
            tester,
            boundaryKey: key,
            brightness: brightness,
            textScale: scale,
            size: const Size(420, _maxHeight),
            fitHeight: true,
            child: OverlaysSheet(focusNode: focus),
          );
          await tester.tap(find.byType(TextField).last); // gerçek dokunuşla odak: odak halkası + yüzen etiket
          await tester.pump(); // animasyonlar bu karede BAŞLAR (ilerlemesi sonraki kare)
          await tester.pump(const Duration(milliseconds: 400));
          await expectGolden(tester, key, 'overlays_$tag.png', pixelRatio: ratio);
          expect(tester.takeException(), isNull);
        });

        testWidgets('düğmeler ve kontroller ($tag)', (tester) async {
          final key = GlobalKey();
          await pumpGallery(
            tester,
            boundaryKey: key,
            brightness: brightness,
            textScale: scale,
            size: const Size(420, _maxHeight),
            fitHeight: true,
            child: const ControlsSheet(),
          );
          final g = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('btn_pressed'))));
          await tester.pump();
          await expectGolden(tester, key, 'controls_$tag.png', pixelRatio: ratio);
          await g.up();
          await tester.pump(const Duration(milliseconds: 400));
          expect(tester.takeException(), isNull);
        });

        testWidgets('gerçek diyalog + modal perde, gerçek zemin ($tag)', (tester) async {
          final key = GlobalKey();
          await pumpGallery(
            tester,
            boundaryKey: key,
            brightness: brightness,
            textScale: scale,
            size: Size(360, scale > 1 ? 1000 : 700),
            realBackground: true,
            child: const RealBackgroundSheet(),
          );
          unawaited(
            showDialog<void>(
              context: tester.element(find.byType(RealBackgroundSheet)),
              builder: (context) => AlertDialog(
                title: const Text('Erişiminiz sona erdi'),
                content: const Text('Misafir erişim süreniz doldu. Yeniden erişim için ev sahibinden yeni bir davet isteyebilirsiniz.'),
                actions: [
                  TextButton(onPressed: () {}, child: const Text('Vazgeç')),
                  FilledButton(onPressed: () {}, child: const Text('Tamam')),
                ],
              ),
            ),
          );
          await tester.pump(); // rota eklenir; geçiş animasyonu bu karede BAŞLAR
          await tester.pump(const Duration(milliseconds: 400));
          expect(find.byType(AlertDialog), findsOneWidget, reason: 'diyalog yakalama sınırının İÇİNDE (Navigator kapsanır)');
          await expectGolden(tester, key, 'dialog_real_$tag.png', pixelRatio: ratio);
          expect(tester.takeException(), isNull);
        });

        testWidgets('gerçek alt sayfa + modal perde, gerçek zemin ($tag)', (tester) async {
          final key = GlobalKey();
          await pumpGallery(
            tester,
            boundaryKey: key,
            brightness: brightness,
            textScale: scale,
            size: Size(360, scale > 1 ? 1000 : 700),
            realBackground: true,
            child: const RealBackgroundSheet(),
          );
          unawaited(
            showModalBottomSheet<void>(
              context: tester.element(find.byType(RealBackgroundSheet)),
              builder: (context) => const SizedBox(
                width: double.infinity,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(20, 20, 20, 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Senaryo seç', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                      SizedBox(height: 12),
                      Row(children: [
                        OrbIconBadge(icon: Icons.nightlight_round, family: AppFamilies.violet),
                        SizedBox(width: 12),
                        Expanded(child: Text('Gece modu')),
                      ]),
                      SizedBox(height: 10),
                      Row(children: [
                        OrbIconBadge(icon: Icons.logout_rounded, family: AppFamilies.amber),
                        SizedBox(width: 12),
                        Expanded(child: Text('Çıkış')),
                      ]),
                    ],
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));
          expect(find.text('Senaryo seç'), findsOneWidget);
          await expectGolden(tester, key, 'sheet_real_$tag.png', pixelRatio: ratio);
          expect(tester.takeException(), isNull);
        });

        testWidgets('gerçek PCB zemini üstünde doğrudan metin ($tag)', (tester) async {
          final key = GlobalKey();
          await pumpGallery(
            tester,
            boundaryKey: key,
            brightness: brightness,
            textScale: scale,
            size: Size(360, scale > 1 ? 1000 : 640),
            realBackground: true,
            child: const RealBackgroundSheet(),
          );
          await tester.pump(const Duration(milliseconds: 300));
          await expectGolden(tester, key, 'realbg_text_$tag.png', pixelRatio: ratio);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }, skip: visualSkipReason);
}
