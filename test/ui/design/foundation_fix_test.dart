import 'dart:ui' as ui;

import 'package:ev_otomasyon/ui/motion/motion.dart';
import 'package:ev_otomasyon/ui/theme/app_theme.dart';
import 'package:ev_otomasyon/ui/theme/slider_shapes.dart';
import 'package:ev_otomasyon/ui/theme/tokens.dart';
import 'package:ev_otomasyon/ui/theme/tone_button_surface.dart';
import 'package:ev_otomasyon/ui/widgets/circuit_background.dart';
import 'package:ev_otomasyon/ui/widgets/orb/orb.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

import 'design_support.dart';

/// WP-F0 (temel düzeltme turu): eleştirmen bulgularından çıkan tema/bileşen sözleşmeleri.
///
/// Koyu ve açık tema AYNI kurucudan çıkar; her sözleşme iki temada denetlenir. Sayılar (kontrast ≥ 3:1 gibi)
/// WCAG 1.4.11 / şartname §5'e bağlıdır, rastgele değildir.
void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  // google_fonts'un asenkron Inter yükleme hatası teste sızmasın: tema hatayı yutan bölgede kurulur.
  final themes = <String, ThemeData Function()>{
    'koyu': () => guardedAppTheme(Brightness.dark),
    'açık': () => guardedAppTheme(Brightness.light),
  };

  /// Bir temanın metin/alan/kart zeminleri (en zor zeminler dahil).
  List<Color> surfacesOf(Brightness b) {
    final t = SurfaceTokens.of(b);
    return b == Brightness.dark
        ? [t.cardTop, t.cardBottom, const Color(0xFF141E33) /* diyalog */, const Color(0xFF0F172A) /* alan dolgusu */]
        : [Colors.white, t.cardBottom, AppTheme.bgLight, const Color(0xFFF8FAFC) /* alan dolgusu */];
  }

  Color muted(Brightness b) => b == Brightness.dark ? AppTheme.textMuted : AppTheme.textMutedLight;

  Future<BuildContext> contextFor(WidgetTester tester, ThemeData theme) async {
    late BuildContext captured;
    await tester.pumpWidget(MaterialApp(theme: theme, home: Builder(builder: (c) {
      captured = c;
      return const SizedBox();
    })));
    await tester.pumpAndSettle();
    return captured;
  }

  // -----------------------------------------------------------------------------------------
  // Giriş alanı: kenar ≥ 3:1, etiket/ipucu/simge soluk
  // -----------------------------------------------------------------------------------------
  group('giriş alanı teması', () {
    for (final e in themes.entries) {
      test('${e.key}: dinlenme kenarı alan dolgusuna, kart yüzeyine ve sayfaya karşı ≥ 3:1 (WCAG 1.4.11)', () {
        final t = e.value();
        final enabled = (t.inputDecorationTheme.enabledBorder! as OutlineInputBorder).borderSide.color;
        final border = (t.inputDecorationTheme.border! as OutlineInputBorder).borderSide.color;
        expect(border, enabled, reason: 'border ve enabledBorder aynı');
        for (final surface in surfacesOf(t.brightness)) {
          expect(AppTheme.contrastRatio(enabled, surface), greaterThanOrEqualTo(3.0), reason: '${e.key} / $surface');
        }
        // Pasif kenar bilerek sönük (pasif bileşenler muaf) ve etkin kenardan farklı.
        final disabled = (t.inputDecorationTheme.disabledBorder! as OutlineInputBorder).borderSide.color;
        expect(disabled, isNot(enabled));
      });

      test('${e.key}: etiket/ipucu odak dışında soluk ve AA; hatada okunur tehlike tonu; pasifte renk verilmez', () {
        final t = e.value();
        final theme = t.inputDecorationTheme;
        final m = muted(t.brightness);
        final danger = AppTheme.readableAccentOn(t.brightness, AppTheme.accentRed);
        final label = theme.labelStyle! as WidgetStateProperty<TextStyle?>;
        final floating = theme.floatingLabelStyle! as WidgetStateProperty<TextStyle?>;
        expect(label.resolve(<WidgetState>{})!.color, m);
        expect(label.resolve({WidgetState.hovered})!.color, m);
        expect(label.resolve({WidgetState.error})!.color, danger);
        expect(label.resolve({WidgetState.disabled})!.color, isNull);
        expect(floating.resolve(<WidgetState>{})!.color, m);
        expect(floating.resolve({WidgetState.error})!.color, danger);
        expect(floating.resolve({WidgetState.disabled})!.color, isNull);
        expect(theme.hintStyle!.color, m);
        for (final surface in surfacesOf(t.brightness)) {
          expect(AppTheme.contrastRatio(m, surface), greaterThanOrEqualTo(4.5), reason: 'soluk etiket AA / $surface');
          expect(AppTheme.contrastRatio(danger, surface), greaterThanOrEqualTo(4.5), reason: 'hata metni AA / $surface');
        }
        expect(AppTheme.contrastRatio(m, theme.fillColor!), lessThan(AppTheme.contrastRatio(t.colorScheme.onSurface, theme.fillColor!)), reason: 'etiket değerden SOLUK');
      });

      test('${e.key}: yardımcı/sayaç/önek-sonek metinleri soluk, hata iletisi okunur tehlike tonu (errorStyle)', () {
        final t = e.value();
        final theme = t.inputDecorationTheme;
        final m = muted(t.brightness);
        expect(theme.helperStyle!.color, m);
        expect(theme.counterStyle!.color, m);
        expect(theme.prefixStyle!.color, m);
        expect(theme.suffixStyle!.color, m);
        expect(theme.errorStyle!.color, AppTheme.readableAccentOn(t.brightness, AppTheme.accentRed));
        // Ham `error` rengi açık temada beyaz üstünde AA'yı tutturmaz (okunur ton bunun için var).
        if (t.brightness == Brightness.light) {
          expect(AppTheme.contrastRatio(AppTheme.accentRed, Colors.white), lessThan(4.5));
        }
      });

      test('${e.key}: alan renkleri tek kaynak (AppTheme.fieldBorder*/fieldFill*): tema ve yerel boyayan ekranlar aynı değeri kullanır', () {
        final t = e.value();
        final dark = t.brightness == Brightness.dark;
        final border = (t.inputDecorationTheme.enabledBorder! as OutlineInputBorder).borderSide.color;
        expect(border, dark ? AppTheme.fieldBorderDark : AppTheme.fieldBorderLight);
        expect(t.inputDecorationTheme.fillColor, dark ? AppTheme.fieldFillDark : AppTheme.fieldFillLight);
      });

      test('${e.key}: önek/sonek simgesi soluk, odakta cyan, pasifte daha sönük', () {
        final t = e.value();
        final focus = t.brightness == Brightness.dark ? AppFamilies.cyan.base : AppFamilies.cyan.deep;
        final m = muted(t.brightness);
        for (final color in [t.inputDecorationTheme.prefixIconColor!, t.inputDecorationTheme.suffixIconColor!]) {
          final p = color as WidgetStateProperty<Color?>;
          expect(p.resolve(<WidgetState>{}), m);
          expect(p.resolve({WidgetState.focused}), focus);
          expect(p.resolve({WidgetState.disabled})!.a, lessThan(m.a));
          expect(AppTheme.contrastRatio(m, t.inputDecorationTheme.fillColor!), greaterThanOrEqualTo(3.0), reason: 'ince simge ≥ 3:1');
        }
      });
    }
  });

  // -----------------------------------------------------------------------------------------
  // Kaydırıcı: pasif iz "oluk" kenarı
  // -----------------------------------------------------------------------------------------
  group('kaydırıcı pasif iz', () {
    for (final e in themes.entries) {
      test('${e.key}: pasif iz kenarı (inactiveRim) kartlara/sayfaya karşı ≥ 3:1', () {
        final t = e.value();
        final shape = t.sliderTheme.trackShape! as GlowSliderTrackShape;
        expect(shape.inactiveRim, isNotNull);
        final surfaces = t.brightness == Brightness.dark
            ? [SurfaceTokens.dark.cardTop, SurfaceTokens.dark.cardBottom, AppTheme.bgDark, const Color(0xFF141E33)]
            : [Colors.white, SurfaceTokens.light.cardBottom, AppTheme.bgLight];
        for (final surface in surfaces) {
          final rim = Color.alphaBlend(shape.inactiveRim!, surface);
          expect(AppTheme.contrastRatio(rim, surface), greaterThanOrEqualTo(3.0), reason: '${e.key} / $surface');
        }
        // Dolgu zemine yakın kalır (oluk içi); kenar onu çerçeveler.
        final fill = Color.alphaBlend(t.sliderTheme.inactiveTrackColor!, surfaces.first);
        expect(AppTheme.contrastRatio(fill, surfaces.first), lessThan(2.0));
        expect(AppTheme.contrastRatio(fill, surfaces.first), greaterThan(1.25), reason: 'eskisi 1.03–1.2:1 idi');
      });

      testWidgets('${e.key}: gerçek çizimde pasif izin alt/üst kenarında ≥ 2.8:1 çizgi var', (tester) async {
        final t = e.value();
        final bg = SurfaceTokens.of(t.brightness).cardTop;
        final key = GlobalKey();
        tester.view.physicalSize = const Size(800, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            theme: t,
            home: Scaffold(
              body: Center(
                child: RepaintBoundary(
                  key: key,
                  child: Container(
                    color: bg,
                    width: 400,
                    height: 48,
                    child: Slider(value: 0.2, onChanged: (_) {}),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final data = await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
          final image = await boundary.toImage(pixelRatio: 2);
          return (await image.toByteData(format: ui.ImageByteFormat.rawRgba), image.width, image.height);
        });
        final bytes = data!.$1!;
        final width = data.$2;
        final height = data.$3;
        Color at(int x, int y) {
          final o = (y * width + x) * 4;
          return Color.fromARGB(255, bytes.getUint8(o), bytes.getUint8(o + 1), bytes.getUint8(o + 2));
        }

        // Pasif bölümün ortası (başparmaktan çok uzak): dikey şeritteki en yüksek kontrast = kenar çizgisi.
        final x = (width * 0.75).round();
        var best = 0.0;
        for (var y = 0; y < height; y++) {
          final c = AppTheme.contrastRatio(at(x, y), bg);
          if (c > best) best = c;
        }
        expect(best, greaterThanOrEqualTo(2.8), reason: '${e.key}: pasif iz kenarı görünür olmalı (en yüksek kontrast $best)');
      });
    }
  });

  // -----------------------------------------------------------------------------------------
  // Diyalog / alt sayfa / çekmece / FAB / başlık yazı tipi
  // -----------------------------------------------------------------------------------------
  group('diyalog, alt sayfa, çekmece, başlıklar', () {
    for (final e in themes.entries) {
      test('${e.key}: diyalog kabuğu (yan boşluk 16, min 328 dp, üst sınır 560, yarıçap 24) ve lacivert perde', () {
        final t = e.value();
        final d = t.dialogTheme;
        final scrim = t.brightness == Brightness.dark ? AppGlass.scrimDark : AppGlass.scrimLight;
        expect(d.insetPadding, const EdgeInsets.symmetric(horizontal: 16, vertical: 24));
        expect(d.constraints, const BoxConstraints(minWidth: 328, maxWidth: 560));
        expect((d.shape! as RoundedRectangleBorder).borderRadius, BorderRadius.circular(AppRadius.dialog));
        expect(AppRadius.dialog, 24);
        expect(d.barrierColor, scrim);
        expect(t.bottomSheetTheme.modalBarrierColor, scrim);
        expect(t.drawerTheme.scrimColor, scrim);
        expect(scrim.a, inInclusiveRange(0.35, 0.7), reason: 'perde ne soluk ne mat siyah');
        // Lacivert ton: mavi bileşen kırmızıdan büyük (varsayılan Colors.black54 nötrdü).
        expect(scrim.b, greaterThan(scrim.r));
      });

      test('${e.key}: AppBar ve diyalog başlıkları gövdeyle AYNI yazı ailesini taşır (platform yazı tipine düşmez)', () {
        final t = e.value();
        final body = t.textTheme.bodyMedium!;
        for (final style in [t.appBarTheme.titleTextStyle!, t.dialogTheme.titleTextStyle!]) {
          expect(style.fontFamily, isNotNull);
          expect(style.fontFamily, body.fontFamily);
          expect(style.fontFamilyFallback, body.fontFamilyFallback);
          expect(style.fontSize, 18);
          expect(style.fontWeight, FontWeight.w700);
        }
      });

      test('${e.key}: çekmece yüzeyi sayfa zemininden ayrışır, kenarı rim + yuvarlak; FAB hap', () {
        final t = e.value();
        final dark = t.brightness == Brightness.dark;
        final page = dark ? AppTheme.bgDark : AppTheme.bgLight;
        final drawer = t.drawerTheme;
        if (dark) expect(drawer.backgroundColor, isNot(page), reason: 'koyuda çekmece sayfadan bir kademe açık');
        expect(drawer.shape, isA<RoundedRectangleBorder>());
        expect((drawer.shape! as RoundedRectangleBorder).side.color, SurfaceTokens.of(t.brightness).rimSolid);
        expect(t.floatingActionButtonTheme.shape, isA<StadiumBorder>());
        expect(t.floatingActionButtonTheme.backgroundColor, AppTheme.primaryBlue);
        expect(AppTheme.contrastRatio(Colors.white, AppTheme.primaryBlue), greaterThanOrEqualTo(4.5), reason: 'FAB etiketi AA');
      });
    }

    testWidgets('AlertDialog 360 dp telefonda 328 dp genişliğinde ve modal perde tema renginde', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      for (final e in themes.entries) {
        await tester.pumpWidget(
          MaterialApp(
            theme: e.value(),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => const AlertDialog(title: Text('Başlık'), content: Text('Kısa içerik'), actions: [Text('Tamam')]),
                  ),
                  child: const Text('aç'),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle(); // tema geçiş animasyonu (AnimatedTheme) bitsin: perde rengi doğru temadan okunur
        await tester.tap(find.text('aç'));
        await tester.pumpAndSettle();
        final material = find.descendant(of: find.byType(AlertDialog), matching: find.byType(Material)).first;
        expect(tester.getSize(material).width, 328, reason: '${e.key}: 360 dp ekranda yan boşluk 16+16');
        final barrier = tester.widget<AnimatedModalBarrier>(find.byType(AnimatedModalBarrier).last);
        final scrim = e.key == 'koyu' ? AppGlass.scrimDark : AppGlass.scrimLight;
        expect(barrier.color.value, scrim, reason: '${e.key}: perde rengi tema belirteci');
        expect(tester.takeException(), isNull);
        Navigator.of(tester.element(find.byType(AlertDialog))).pop();
        await tester.pumpAndSettle();
      }
    });

    testWidgets('AlertDialog 320 dp en dar telefonda minWidth 328 ebeveyn sınırına kırpılır (288 dp), taşma yok', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      for (final e in themes.entries) {
        await tester.pumpWidget(
          MaterialApp(
            theme: e.value(),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => const AlertDialog(title: Text('Başlık'), content: Text('Kısa içerik'), actions: [Text('Tamam')]),
                  ),
                  child: const Text('aç'),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('aç'));
        await tester.pumpAndSettle();
        final material = find.descendant(of: find.byType(AlertDialog), matching: find.byType(Material)).first;
        expect(tester.getSize(material).width, 288, reason: '${e.key}: 320 dp ekranda yan boşluk 16+16; min 328 sınıra kırpılır');
        expect(tester.takeException(), isNull, reason: '${e.key}: dar ekranda taşma/kısıt hatası olmamalı');
        Navigator.of(tester.element(find.byType(AlertDialog))).pop();
        await tester.pumpAndSettle();
      }
    });

    for (final size in const [Size(360, 800), Size(800, 360), Size(1200, 800)]) {
      testWidgets('SDK diyalogları (showTimePicker) tema kabuğuyla ${size.width.toInt()}x${size.height.toInt()} ekranda taşmadan açılır', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            theme: guardedAppTheme(Brightness.dark),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showTimePicker(context: context, initialTime: const TimeOfDay(hour: 21, minute: 30)),
                  child: const Text('aç'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('aç'));
        await tester.pumpAndSettle();
        expect(find.byType(TimePickerDialog), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'minWidth/insetPadding SDK seçicisini taşırmamalı');
      });
    }

    testWidgets('geniş ekranda diyalog 328 dp\'den küçük olmaz ve 560 dp\'yi aşmaz', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: guardedAppTheme(Brightness.light),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => AlertDialog(title: const Text('Başlık'), content: Text('Uzun metin ' * 80), actions: const [Text('Tamam')]),
                ),
                child: const Text('aç'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('aç'));
      await tester.pumpAndSettle();
      final material = find.descendant(of: find.byType(AlertDialog), matching: find.byType(Material)).first;
      final w = tester.getSize(material).width;
      expect(w, inInclusiveRange(328, 560));
    });
  });

  // -----------------------------------------------------------------------------------------
  // Çip ve anahtar
  // -----------------------------------------------------------------------------------------
  group('çip ve anahtar', () {
    for (final e in themes.entries) {
      test('${e.key}: seçili çip kenarı odak halkasıyla aynı cyan, 1.5 px ve yüzeylere karşı ≥ 3:1; seçilmemiş 1 px', () {
        final t = e.value();
        final focus = t.brightness == Brightness.dark ? AppFamilies.cyan.base : AppFamilies.cyan.deep;
        final side = t.chipTheme.side! as WidgetStateProperty<BorderSide?>;
        final selected = side.resolve({WidgetState.selected})!;
        final plain = side.resolve(<WidgetState>{})!;
        expect(selected.color, focus);
        expect(selected.width, 1.5);
        expect(plain.width, 1.0);
        expect(plain.color, isNot(selected.color));
        for (final surface in surfacesOf(t.brightness).take(3)) {
          expect(AppTheme.contrastRatio(focus, surface), greaterThanOrEqualTo(3.0), reason: '${e.key} / $surface');
        }
        expect(t.chipTheme.shape, isA<StadiumBorder>());
        expect(t.chipTheme.selectedColor, t.colorScheme.secondaryContainer, reason: 'M3 çifti korunur');
      });

      test('${e.key}: salt-okunur AÇIK anahtar gri değil soluk zümrüt; salt-okunur KAPALI gri', () {
        final t = e.value();
        final track = t.switchTheme.trackColor!;
        final thumb = t.switchTheme.thumbColor!;
        final onTrack = track.resolve({WidgetState.disabled, WidgetState.selected})!;
        final offTrack = track.resolve({WidgetState.disabled})!;
        final hue = HSLColor.fromColor(onTrack).hue;
        expect((hue - HSLColor.fromColor(AppFamilies.emerald.base).hue).abs(), lessThan(1.0), reason: 'zümrüt tonu');
        expect(onTrack.a, inInclusiveRange(0.3, 0.6));
        expect(HSLColor.fromColor(offTrack).saturation, lessThan(0.4), reason: 'kapalı pasif nötr (zümrüt değil)');
        expect((HSLColor.fromColor(offTrack).hue - HSLColor.fromColor(AppFamilies.emerald.base).hue).abs(), greaterThan(20));
        expect(thumb.resolve({WidgetState.disabled, WidgetState.selected}), isNot(thumb.resolve({WidgetState.disabled})));
        // Etkin AÇIK: sabit zümrüt iz + beyaz başparmak.
        expect(track.resolve({WidgetState.selected}), AppFamilies.emerald.base);
        expect(thumb.resolve({WidgetState.selected}), Colors.white);
        expect(t.switchTheme.overlayColor!.resolve({WidgetState.selected, WidgetState.pressed})!.a, greaterThan(0.1));
        expect(t.switchTheme.overlayColor!.resolve({WidgetState.disabled}), isNull);
      });
    }
  });

  // -----------------------------------------------------------------------------------------
  // Düğme dış renkli gölgesi (Material yükseltme gölgesi)
  // -----------------------------------------------------------------------------------------
  group('düğme dış gölgesi', () {
    test('ToneButtonSurface.elevationFor: pasif 0, basılı 3, dinlenme 8', () {
      expect(ToneButtonSurface.elevationFor(<WidgetState>{}), ToneButtonSurface.restElevation);
      expect(ToneButtonSurface.elevationFor({WidgetState.pressed}), ToneButtonSurface.pressedElevation);
      expect(ToneButtonSurface.elevationFor({WidgetState.disabled}), 0);
      expect(ToneButtonSurface.elevationFor({WidgetState.disabled, WidgetState.pressed}), 0, reason: 'pasif düğmede gölge hayaleti YOK');
      expect(ToneButtonSurface.pressedElevation, lessThan(ToneButtonSurface.restElevation));
    });

    for (final e in themes.entries) {
      test('${e.key}: ElevatedButton ve FilledButton teması gölge verir (sky), geçişler anında', () {
        final t = e.value();
        for (final style in [t.elevatedButtonTheme.style!, t.filledButtonTheme.style!]) {
          expect(style.elevation!.resolve(<WidgetState>{}), 8);
          expect(style.elevation!.resolve({WidgetState.pressed}), 3);
          expect(style.elevation!.resolve({WidgetState.disabled}), 0);
          expect(style.shadowColor!.resolve(<WidgetState>{}), AppFamilies.sky.base);
          expect(style.animationDuration, Duration.zero, reason: 'basma geri bildirimi ANINDA: yükseltmede tween yok');
          expect(style.surfaceTintColor!.resolve(<WidgetState>{}), Colors.transparent);
        }
      });
    }

    test('toneButtonStyle: gölge rengi ton parıltı rengi, pasifte 0', () {
      for (final family in AppFamilies.all) {
        final style = toneButtonStyle(family);
        expect(style.shadowColor!.resolve(<WidgetState>{}), ButtonTone.fromFamily(family).glow, reason: family.name);
        expect(style.elevation!.resolve({WidgetState.disabled}), 0);
        expect(style.elevation!.resolve(<WidgetState>{}), ToneButtonSurface.restElevation);
        expect(style.animationDuration, Duration.zero);
      }
    });

    testWidgets('gerçek düğmede Material yükseltmesi: dinlenme 8, basılı 3, pasif 0 (ElevatedButton, FilledButton, tone)', (tester) async {
      Material materialOf(Finder button) => tester.widget<Material>(find.descendant(of: button, matching: find.byType(Material)).first);
      await tester.pumpWidget(
        MaterialApp(
          theme: guardedAppTheme(Brightness.dark),
          home: Scaffold(
            body: Column(
              children: [
                ElevatedButton(key: const Key('el'), onPressed: () {}, child: const Text('E')),
                FilledButton(key: const Key('fi'), onPressed: () {}, child: const Text('F')),
                ElevatedButton(key: const Key('to'), onPressed: () {}, style: toneButtonStyle(AppFamilies.rose), child: const Text('T')),
                const ElevatedButton(key: Key('di'), onPressed: null, child: Text('D')),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final k in ['el', 'fi', 'to']) {
        final m = materialOf(find.byKey(Key(k)));
        expect(m.elevation, 8, reason: k);
      }
      expect(materialOf(find.byKey(const Key('el'))).shadowColor, AppFamilies.sky.base);
      expect(materialOf(find.byKey(const Key('to'))).shadowColor, ButtonTone.fromFamily(AppFamilies.rose).glow);
      expect(materialOf(find.byKey(const Key('di'))).elevation, 0);
      final g = await tester.startGesture(tester.getCenter(find.byKey(const Key('el'))));
      await tester.pump();
      expect(materialOf(find.byKey(const Key('el'))).elevation, 3, reason: 'basınçta ANINDA (animasyon yok)');
      await g.up();
      await tester.pump();
      expect(materialOf(find.byKey(const Key('el'))).elevation, 8);
      expect(tester.takeException(), isNull);
    });
  });

  // -----------------------------------------------------------------------------------------
  // Belirteçler
  // -----------------------------------------------------------------------------------------
  group('belirteçler', () {
    test('AppText: hepsi AppTouch.minFontSize (12 sp) ve üstü, artan sırada', () {
      final sizes = [AppText.badge, AppText.caption, AppText.body, AppText.cardTitle, AppText.title, AppText.metric];
      for (final size in sizes) {
        expect(size, greaterThanOrEqualTo(AppTouch.minFontSize));
      }
      for (var i = 1; i < sizes.length; i++) {
        expect(sizes[i], greaterThan(sizes[i - 1]));
      }
      expect(AppText.title, 18, reason: 'AppBar/diyalog başlığı ile aynı');
    });

    test('AppRadius.dialog = 24 ve dialogTheme bunu kullanır; mevcut yarıçaplar değişmedi', () {
      expect(AppRadius.dialog, 24);
      expect([AppRadius.r8, AppRadius.r12, AppRadius.r16, AppRadius.card, AppRadius.sheet, AppRadius.pill], [8, 12, 16, 20, 28, 999]);
    });

    test('AppGlass: orb parıltı seviyeleri ve modal perde belirteçleri', () {
      expect(AppGlass.orbGlowIdle, lessThan(AppGlass.orbGlowActive));
      expect(AppGlass.orbGlowIdle, inExclusiveRange(0, 1));
      expect(AppGlass.scrimDark.a, greaterThan(AppGlass.scrimLight.a), reason: 'koyuda perde daha yoğun');
      expect(AppGlass.accentTintAlphaDark, 0.02);
      expect(AppGlass.accentGlowAlphaLight, lessThan(0.18), reason: 'eski açık tema parıltısı (0.18) geniş kartta bulut lekesiydi');
    });
  });

  // -----------------------------------------------------------------------------------------
  // Okunabilir ton yardımcıları
  // -----------------------------------------------------------------------------------------
  group('AppTheme yardımcıları: readableAccentBorder, accentTone, readableFamily, quietTextButtonStyle', () {
    final accents = <Color>[
      AppTheme.accentAmber,
      AppTheme.accentGreen,
      AppTheme.accentCyan,
      AppTheme.accentPurple,
      AppTheme.accentRed,
      AppTheme.primaryBlue,
      Colors.cyanAccent,
      Colors.amber,
      for (final f in AppFamilies.all) f.base,
    ];

    testWidgets('açık temada çerçeve tonu beyaz ve sayfa zemininde ≥ 3:1; ton korunur; yeterliyse DEĞİŞMEZ', (tester) async {
      final ctx = await contextFor(tester, guardedAppTheme(Brightness.light));
      for (final accent in accents) {
        final c = AppTheme.readableAccentBorder(ctx, accent);
        expect(AppTheme.contrastRatio(c, Colors.white), greaterThanOrEqualTo(3.0), reason: '$accent');
        expect(AppTheme.contrastRatio(c, AppTheme.bgLight), greaterThanOrEqualTo(3.0), reason: '$accent');
        final before = HSLColor.fromColor(accent);
        final after = HSLColor.fromColor(c);
        if (before.saturation > 0.2 && after.lightness > 0.1) {
          var hueDelta = (before.hue - after.hue).abs();
          if (hueDelta > 180) hueDelta = 360 - hueDelta;
          expect(hueDelta, lessThan(12), reason: 'ton korunur: $accent → $c');
        }
        if (AppTheme.contrastRatio(accent, Colors.white) >= 3.0 && AppTheme.contrastRatio(accent, AppTheme.bgLight) >= 3.0) {
          expect(c, accent, reason: 'zaten yeterli renk değişmez');
        }
        // Ham amber/cyanAccent açıkta kenar olarak YETERSİZDİ: yardımcı onları koyulaştırır.
      }
      expect(AppTheme.contrastRatio(Colors.cyanAccent, Colors.white), lessThan(3.0));
      expect(AppTheme.readableAccentBorder(ctx, Colors.cyanAccent), isNot(Colors.cyanAccent));
    });

    testWidgets('readableAccentOn(parlaklık) bağlamlı readableAccent ile AYNI sonucu verir; getFieldBorder/getFieldFill', (tester) async {
      for (final e in themes.entries) {
        final ctx = await contextFor(tester, e.value());
        final b = e.value().brightness;
        for (final accent in accents) {
          expect(AppTheme.readableAccentOn(b, accent), AppTheme.readableAccent(ctx, accent), reason: '${e.key} $accent');
        }
        expect(AppTheme.getFieldBorder(ctx), b == Brightness.dark ? AppTheme.fieldBorderDark : AppTheme.fieldBorderLight);
        expect(AppTheme.getFieldFill(ctx), b == Brightness.dark ? AppTheme.fieldFillDark : AppTheme.fieldFillLight);
      }
    });

    testWidgets('koyu temada ham vurgu rengi aynen döner', (tester) async {
      final ctx = await contextFor(tester, guardedAppTheme(Brightness.dark));
      for (final accent in accents) {
        expect(AppTheme.readableAccentBorder(ctx, accent), accent);
      }
    });

    testWidgets('accentTone: koyuda family.light, açıkta family.deep; readableFamily = readableAccent(base)', (tester) async {
      final dark = await contextFor(tester, guardedAppTheme(Brightness.dark));
      for (final f in AppFamilies.all) {
        expect(AppTheme.accentTone(dark, f), f.light);
        expect(AppTheme.readableFamily(dark, f), AppTheme.readableAccent(dark, f.base));
      }
      final light = await contextFor(tester, guardedAppTheme(Brightness.light));
      for (final f in AppFamilies.all) {
        expect(AppTheme.accentTone(light, f), f.deep);
        expect(AppTheme.readableFamily(light, f), AppTheme.readableAccent(light, f.base));
        expect(AppTheme.contrastRatio(AppTheme.readableFamily(light, f), Colors.white), greaterThanOrEqualTo(4.5), reason: f.name);
      }
    });

    testWidgets('quietTextButtonStyle: soluk ön plan (iptal/geri), pasifte daha sönük', (tester) async {
      for (final e in themes.entries) {
        final ctx = await contextFor(tester, e.value());
        final style = AppTheme.quietTextButtonStyle(ctx);
        expect(style.foregroundColor!.resolve(<WidgetState>{}), AppTheme.getTextMuted(ctx));
        expect(style.foregroundColor!.resolve({WidgetState.disabled})!.a, lessThan(1.0));
      }
    });
  });

  // -----------------------------------------------------------------------------------------
  // Cam yüzey tonları
  // -----------------------------------------------------------------------------------------
  group('cam yüzey: accent tonu ve parıltı alfaları', () {
    testWidgets('vurgulu olmayan accent\'li kart: koyuda 0.02, açıkta 0.05 gövde tonu', (tester) async {
      const accent = Color(0xFFFFB020);
      final dark = await contextFor(tester, guardedAppTheme(Brightness.dark));
      final dg = AppTheme.cardDecoration(dark, accent: accent).gradient! as LinearGradient;
      expect(dg.colors.first, Color.alphaBlend(accent.withValues(alpha: AppGlass.accentTintAlphaDark), SurfaceTokens.dark.cardTop));
      expect(AppGlass.accentTintAlphaDark, lessThan(AppGlass.accentTintAlphaLight));
      final light = await contextFor(tester, guardedAppTheme(Brightness.light));
      final lg = AppTheme.cardDecoration(light, accent: accent).gradient! as LinearGradient;
      expect(lg.colors.first, Color.alphaBlend(accent.withValues(alpha: AppGlass.accentTintAlphaLight), SurfaceTokens.light.cardTop));
      // Sıcak tonlu hafif tint koyu kartı kirletmez: kart üst rengine çok yakın kalır.
      expect(AppTheme.contrastRatio(dg.colors.first, SurfaceTokens.dark.cardTop), lessThan(1.05));
    });

    testWidgets('vurgulu kart parıltısı: koyuda accentGlowAlpha (0.14), açıkta accentGlowAlphaLight (daha zayıf)', (tester) async {
      const accent = Color(0xFF22D3EE);
      final dark = await contextFor(tester, guardedAppTheme(Brightness.dark));
      final dr = AppTheme.cardDecoration(dark, accent: accent, emphasized: true).gradient! as RadialGradient;
      expect(dr.colors.first, Color.alphaBlend(accent.withValues(alpha: AppGlass.accentGlowAlpha), SurfaceTokens.dark.cardTop));
      final light = await contextFor(tester, guardedAppTheme(Brightness.light));
      final lr = AppTheme.cardDecoration(light, accent: accent, emphasized: true).gradient! as RadialGradient;
      expect(lr.colors.first, Color.alphaBlend(accent.withValues(alpha: AppGlass.accentGlowAlphaLight), SurfaceTokens.light.cardTop));
      expect(AppGlass.accentGlowAlphaLight, lessThan(0.14 + 0.04), reason: 'eskisi 0.18 idi: geniş kartta bulut lekesi');
      expect(AppGlass.accentGlowAlpha, 0.14, reason: 'pinli belirteç değişmez');
    });

    testWidgets('getDrawerBg: koyuda surfaceDark (sayfadan ayrışır), açıkta bgLight', (tester) async {
      final dark = await contextFor(tester, guardedAppTheme(Brightness.dark));
      expect(AppTheme.getDrawerBg(dark), AppTheme.surfaceDark);
      expect(AppTheme.getDrawerBg(dark), isNot(AppTheme.bgDark));
      final light = await contextFor(tester, guardedAppTheme(Brightness.light));
      expect(AppTheme.getDrawerBg(light), AppTheme.bgLight);
    });
  });

  // -----------------------------------------------------------------------------------------
  // İskelet
  // -----------------------------------------------------------------------------------------
  group('iskelet', () {
    test('iki temada da parıltı bandı tabandan AÇIK ve taban görünür (açıkta eskiden band KOYUYDU)', () {
      Color blend(Color top, Color bottom) => Color.alphaBlend(top, bottom);
      final cases = <String, (Color, Color, List<Color>)>{
        'koyu': (Skeleton.skeletonBaseDark, Skeleton.skeletonHighlightDark, [SurfaceTokens.dark.cardTop, SurfaceTokens.dark.cardBottom]),
        'açık': (Skeleton.skeletonBaseLight, Skeleton.skeletonHighlightLight, [Colors.white, SurfaceTokens.light.cardBottom]),
      };
      for (final c in cases.entries) {
        final (base, highlight, surfaces) = c.value;
        for (final surface in surfaces) {
          final resting = blend(base, surface);
          final band = blend(highlight, resting);
          expect(band.computeLuminance(), greaterThan(resting.computeLuminance()), reason: '${c.key}: band tabandan açık');
          expect(AppTheme.contrastRatio(resting, surface), greaterThan(c.key == 'açık' ? 1.28 : 1.3), reason: '${c.key}: taban kartta belirgin görünür');
          // Süpürme bandı tabandan belirgin açık (en az ~%12 parlaklık farkı): "parlayan süpürme" görünür.
          expect(band.computeLuminance(), greaterThan(resting.computeLuminance() * 1.1), reason: '${c.key}: band görünür');
        }
      }
    });

    for (final scale in [1.0, 1.5, 2.0]) {
      testWidgets('SkeletonText: yükseklik yazı ölçeğiyle büyür (ölçek $scale): gerçek 28 sp sayıyla aynı satır yüksekliği', (tester) async {
        await tester.pumpWidget(
          designHost(
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SkeletonText(width: 64, fontSize: 28, lineHeight: 1.1, key: Key('sk')),
                Text('48', key: const Key('real'), style: const TextStyle(fontSize: 28, height: 1.1)),
              ],
            ),
            textScale: scale,
          ),
        );
        final skeletonLine = tester.getSize(find.byKey(const Key('sk'))).height;
        final realLine = tester.getSize(find.byKey(const Key('real'))).height;
        expect(skeletonLine, closeTo(realLine, 0.6), reason: 'veri gelince düzen zıplamaz');
        // Çubuk satırdan kısadır (satır kutusunun %78'i).
        final bar = tester.getSize(find.descendant(of: find.byKey(const Key('sk')), matching: find.byType(Skeleton)));
        expect(bar.height, lessThan(skeletonLine));
        expect(bar.width, 64);
      });
    }
  });

  // -----------------------------------------------------------------------------------------
  // Orb
  // -----------------------------------------------------------------------------------------
  group('orb', () {
    OrbCore coreOf(WidgetTester tester) => tester.widget<OrbCore>(find.byType(OrbCore).first);

    testWidgets('OrbIconBadge: glow varsayılanı TEMAYA göre (koyuda açık, açıkta kapalı); açık değer aynen; active her zaman', (tester) async {
      await tester.pumpWidget(designHost(const OrbIconBadge(icon: Icons.home, family: AppFamilies.cyan)));
      expect(coreOf(tester).glow, isTrue, reason: 'koyu tema: soluk idle parıltı');
      await tester.pumpWidget(designHost(const OrbIconBadge(icon: Icons.home, family: AppFamilies.cyan), brightness: Brightness.light));
      await tester.pumpAndSettle();
      expect(coreOf(tester).glow, isFalse, reason: 'açık tema: renkli statik gölge zaten var');
      await tester.pumpWidget(designHost(const OrbIconBadge(icon: Icons.home, family: AppFamilies.cyan, glow: false)));
      await tester.pumpAndSettle();
      expect(coreOf(tester).glow, isFalse, reason: 'açık glow:false koyuda da uygulanır (yoğun liste)');
      await tester.pumpWidget(designHost(const OrbIconBadge(icon: Icons.home, family: AppFamilies.cyan, glow: true), brightness: Brightness.light));
      await tester.pumpAndSettle();
      expect(coreOf(tester).glow, isTrue);
      await tester.pumpWidget(designHost(const OrbIconBadge(icon: Icons.home, family: AppFamilies.cyan, glow: false, active: true), brightness: Brightness.light));
      await tester.pumpAndSettle();
      expect(coreOf(tester).glow, isTrue, reason: 'active rozet daima parlar');
    });

    testWidgets('OrbIconBadge.iconBuilder: simge yerine özel simge (marka işareti); icon olmadan da kurulur; ikisi de yoksa assert', (tester) async {
      await tester.pumpWidget(
        designHost(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              OrbIconBadge(iconBuilder: OrbIcons.letter('G'), family: AppFamilies.sky),
              OrbIconBadge(iconBuilder: OrbIcons.triangle(up: true), family: AppFamilies.emerald, size: OrbSize.md),
              const OrbIconBadge(icon: Icons.home, family: AppFamilies.cyan),
            ],
          ),
        ),
      );
      expect(find.text('G'), findsOneWidget);
      final cores = tester.widgetList<OrbCore>(find.byType(OrbCore)).toList();
      expect(cores, hasLength(3));
      expect(cores[0].iconBuilder, isNotNull);
      expect(cores[0].icon, isNull);
      expect(cores[2].iconBuilder, isNull, reason: 'varsayılan davranış aynı: simge IconData ile');
      expect(cores[2].icon, Icons.home);
      expect(find.byIcon(Icons.home), findsOneWidget);
      // Renk orb'un simge rengi: builder'a gelen renk gövde üstünde ≥ 3:1 seçilmiş OrbColors.icon.
      final text = tester.widget<Text>(find.text('G'));
      expect(text.style!.color, OrbColors.family(AppFamilies.sky).icon);
      expect(() => OrbIconBadge(family: AppFamilies.sky), throwsAssertionError);
      expect(tester.takeException(), isNull);
    });

    testWidgets('boşta parıltı koyuda gerçekten çizilir (idle seviyesi), devre dışıda çizilmez', (tester) async {
      Future<double> level(Widget w) async {
        await tester.pumpWidget(designHost(w));
        await tester.pumpAndSettle();
        return tester.widgetList<CustomPaint>(find.byType(CustomPaint)).map((c) => c.painter).whereType<OrbPainter>().first.glowLevel;
      }

      expect(await level(const OrbIconBadge(icon: Icons.home, family: AppFamilies.amber)), AppGlass.orbGlowIdle);
      expect(await level(const OrbIconBadge(icon: Icons.home, family: AppFamilies.amber, active: true)), AppGlass.orbGlowActive);
      expect(await level(const OrbIconBadge(icon: Icons.home, family: AppFamilies.amber, enabled: false)), 0.0);
      expect(AppGlass.orbGlowIdle, lessThan(AppGlass.orbGlowActive));
    });

    test('OrbPainter: sıcak tonlu parıltı (amber/rose) koyuda güçlendirilir, soğuk ve nötr tonlar değil', () {
      for (final f in [AppFamilies.amber, AppFamilies.rose]) {
        expect(OrbPainter.warmGlowGain(f.glow), OrbPainter.warmGainDark, reason: f.name);
        expect(OrbPainter(colors: OrbColors.family(f), dark: true).warmGain, OrbPainter.warmGainDark);
      }
      for (final f in [AppFamilies.sky, AppFamilies.emerald, AppFamilies.violet, AppFamilies.cyan, AppFamilies.slate]) {
        expect(OrbPainter.warmGlowGain(f.glow), 1.0, reason: f.name);
      }
      expect(OrbPainter.warmGainDark, greaterThan(1.0));
    });

    testWidgets('başarı halkası tema duyarlı: koyuda emerald.light, açıkta emerald.deep; en çok OrbCore.ringMaxScale', (tester) async {
      for (final dark in [true, false]) {
        final status = ValueNotifier<OrbStatus>(OrbStatus.none);
        addTearDown(status.dispose);
        final clock = AmbientClock.fixed(0.5);
        addTearDown(clock.dispose);
        await tester.pumpWidget(
          designHost(
            ValueListenableBuilder<OrbStatus>(
              valueListenable: status,
              builder: (_, s, _) => OrbButton(icon: Icons.check, family: AppFamilies.sky, semanticLabel: 'o', onTap: () {}, status: s),
            ),
            mode: MotionMode.full,
            brightness: dark ? Brightness.dark : Brightness.light,
            clock: clock,
          ),
        );
        await tester.pumpAndSettle();
        status.value = OrbStatus.success;
        await tester.pump();
        final ring = tester.widget<PulseRing>(find.byType(PulseRing));
        expect(ring.color, dark ? AppFamilies.emerald.light : AppFamilies.emerald.deep, reason: dark ? 'koyu' : 'açık');
        expect(ring.maxScale, OrbCore.ringMaxScale);
        expect(OrbCore.ringMaxScale, lessThan(1.55), reason: 'PulseRing varsayılanından küçük: komşu orb/etiketle çakışmaz');
        await tester.pumpAndSettle();
      }
    });

    testWidgets('OrbToggle: salt-okunur (onChanged null) devre dışı + mutedFamily; etkinken enabled', (tester) async {
      await tester.pumpWidget(
        designHost(
          const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              OrbToggle(value: true, onChanged: null, icon: Icons.lightbulb_outline, activeIcon: Icons.lightbulb, family: AppFamilies.amber, semanticLabel: 'ro'),
            ],
          ),
        ),
      );
      var core = coreOf(tester);
      expect(core.enabled, isFalse);
      expect(core.mutedFamily, isTrue);
      expect(core.progress, 1.0);
      await tester.pumpWidget(
        designHost(OrbToggle(value: true, onChanged: (_) {}, icon: Icons.lightbulb_outline, family: AppFamilies.amber, semanticLabel: 'rw')),
      );
      core = coreOf(tester);
      expect(core.enabled, isTrue);
    });

    testWidgets('OrbButton devre dışı: mutedFamily YOK (düz gri küre)', (tester) async {
      await tester.pumpWidget(designHost(const OrbButton(icon: Icons.stop, family: AppFamilies.rose, semanticLabel: 'x')));
      final core = coreOf(tester);
      expect(core.enabled, isFalse);
      expect(core.mutedFamily, isFalse);
    });

    OrbPainter painterOf(WidgetTester tester) =>
        tester.widgetList<CustomPaint>(find.byType(CustomPaint)).map((c) => c.painter).whereType<OrbPainter>().first;

    testWidgets('dimmed OrbButton: ETKİN kalır (dokunuş çalışır), soluk aile gövdesi, parıltı ve nefes YOK', (tester) async {
      var taps = 0;
      final clock = AmbientClock();
      addTearDown(clock.dispose);
      await tester.pumpWidget(
        designHost(
          OrbButton(key: const Key('o'), icon: Icons.stop, family: AppFamilies.rose, semanticLabel: 'x', active: true, dimmed: true, onTap: () => taps++),
          mode: MotionMode.full,
          clock: clock,
        ),
      );
      final core = coreOf(tester);
      expect(core.dimmed, isTrue);
      expect(core.enabled, isTrue, reason: 'dokunuş/anlamsal ağaç aynen');
      final painter = painterOf(tester);
      expect(painter.glowLevel, 0.0, reason: 'parıltı yok');
      expect(painter.clock, isNull, reason: 'active olsa da nefes slotu alınmaz');
      expect(clock.isTicking, isFalse);
      final muted = OrbColors.mutedFamily(AppFamilies.rose, Brightness.dark, OrbCore.mutedFamilyMix);
      expect(painter.colors, muted);
      expect(painter.colors.base, isNot(OrbColors.family(AppFamilies.rose).base));
      await tester.tap(find.byKey(const Key('o')));
      expect(taps, 1, reason: 'soluk orb dokunuşu KABUL eder');
      final handle = tester.ensureSemantics();
      await tester.pump();
      final semantics = tester.getSemantics(find.byKey(const Key('o')));
      expect(semantics.flagsCollection.isEnabled.toBoolOrNull(), isTrue, reason: 'anlamsal olarak da etkin');
      handle.dispose();
    });

    testWidgets('dimmed OrbToggle: AÇIK soluk aile gövdesi, KAPALI normal cam küre; parıltı yok', (tester) async {
      await tester.pumpWidget(
        designHost(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              OrbToggle(value: true, onChanged: (_) {}, icon: Icons.lightbulb_outline, activeIcon: Icons.lightbulb, family: AppFamilies.amber, semanticLabel: 'a', dimmed: true),
              OrbToggle(value: false, onChanged: (_) {}, icon: Icons.lightbulb_outline, family: AppFamilies.amber, semanticLabel: 'b', dimmed: true),
            ],
          ),
        ),
      );
      final painters = tester.widgetList<CustomPaint>(find.byType(CustomPaint)).map((c) => c.painter).whereType<OrbPainter>().toList();
      expect(painters, hasLength(2));
      expect(painters[0].colors, OrbColors.mutedFamily(AppFamilies.amber, Brightness.dark, OrbCore.mutedFamilyMix));
      expect(painters[0].glowLevel, 0.0);
      expect(painters[1].colors, OrbColors.glass(Brightness.dark), reason: 'kapalı anahtarda soluklaştıracak aile rengi yok');
    });

    testWidgets('dimmed OrbIconBadge: parıltı glow:true olsa da yok, gövde soluk; açık temada renkli gölge nötr', (tester) async {
      await tester.pumpWidget(designHost(const OrbIconBadge(icon: Icons.home, family: AppFamilies.emerald, glow: true, dimmed: true)));
      expect(painterOf(tester).glowLevel, 0.0);
      expect(painterOf(tester).colors, OrbColors.mutedFamily(AppFamilies.emerald, Brightness.dark, OrbCore.mutedFamilyMix));
      await tester.pumpWidget(designHost(const OrbIconBadge(icon: Icons.home, family: AppFamilies.emerald, dimmed: true), brightness: Brightness.light));
      await tester.pumpAndSettle();
      final shadow = tester.widget<DecoratedBox>(find.descendant(of: find.byKey(const ValueKey('orb_shadow')), matching: find.byType(DecoratedBox)));
      final box = (shadow.decoration as BoxDecoration).boxShadow!.single;
      expect(box.color, const Color(0x1A101820), reason: 'soluk orb renkli gölge taşımaz');
      await tester.pumpWidget(designHost(const OrbIconBadge(icon: Icons.home, family: AppFamilies.emerald), brightness: Brightness.light));
      await tester.pumpAndSettle();
      final colored = tester.widget<DecoratedBox>(find.descendant(of: find.byKey(const ValueKey('orb_shadow')), matching: find.byType(DecoratedBox)));
      expect((colored.decoration as BoxDecoration).boxShadow!.single.color, isNot(const Color(0x1A101820)));
    });

    // Soluk aile gövdesi üzerinde simge rengi ≥ 3:1 (gerçek çizilen piksellerle; her aile, iki tema). Simge rengi
    // gövdeye göre seçilir (açık amber/cyan üstünde devre dışı açık gri simge yetmez).
    for (final brightness in [Brightness.dark, Brightness.light]) {
      testWidgets('salt-okunur AÇIK orb (soluk aile gövdesi) simgesi ${brightness.name} temada ≥ 3:1', (tester) async {
        const d = 128.0;
        final grey = OrbColors.disabled(brightness);
        for (final family in AppFamilies.all) {
          final colors = OrbColors.mutedFamily(family, brightness, OrbCore.mutedFamilyMix);
          expect(colors.glowScale, 0.0, reason: 'parıltı yok');
          expect(colors.specular, grey.specular, reason: 'speküler devre dışı takımından');
          expect(colors.base, isNot(grey.base), reason: '${family.name}: gövde aile tonuna kaymış');
          final rgba = await tester.runAsync(() async {
            final recorder = ui.PictureRecorder();
            final canvas = Canvas(recorder);
            paintOrbBody(canvas, const Offset(d / 2, d / 2), d / 2, colors);
            final image = await recorder.endRecording().toImage(d.toInt(), d.toInt());
            final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
            image.dispose();
            return data!;
          });
          const half = 0.22 * d;
          var worst = double.infinity;
          for (var iy = 0; iy < 5; iy++) {
            for (var ix = 0; ix < 5; ix++) {
              final x = (d / 2 - half + (2 * half) * ix / 4).round().clamp(0, d.toInt() - 1);
              final y = (d / 2 - half + (2 * half) * iy / 4).round().clamp(0, d.toInt() - 1);
              final o = (y * d.toInt() + x) * 4;
              final p = Color.fromARGB(255, rgba!.getUint8(o), rgba.getUint8(o + 1), rgba.getUint8(o + 2));
              final r = AppTheme.contrastRatio(colors.icon, p);
              if (r < worst) worst = r;
            }
          }
          expect(worst, greaterThanOrEqualTo(3.0), reason: '${family.name} ${brightness.name}: en kötü ${worst.toStringAsFixed(2)}');
        }
      });
    }

    test('OrbColors.mutedFamily: önbellekli (aynı nesne), mix 0 → devre dışı gri; mix büyüdükçe aileye kayar', () {
      for (final brightness in [Brightness.dark, Brightness.light]) {
        final a = OrbColors.mutedFamily(AppFamilies.rose, brightness, 0.4);
        expect(identical(a, OrbColors.mutedFamily(AppFamilies.rose, brightness, 0.4)), isTrue);
        expect(OrbColors.mutedFamily(AppFamilies.rose, brightness, 0.0), OrbColors.disabled(brightness));
        final weak = OrbColors.mutedFamily(AppFamilies.rose, brightness, 0.2);
        double redness(Color c) => c.r - c.b;
        expect(redness(a.base), greaterThan(redness(weak.base)));
        expect(redness(weak.base), greaterThan(redness(OrbColors.disabled(brightness).base)));
      }
    });

    testWidgets('OrbIcons: dolu üçgen ve harf iconBuilder\'ları hatasız çizilir; boyut orb simge kutusu kadar', (tester) async {
      await tester.pumpWidget(
        designHost(
          Wrap(
            children: [
              OrbButton(iconBuilder: OrbIcons.triangle(up: true), family: AppFamilies.emerald, semanticLabel: 'yukarı', onTap: () {}),
              OrbButton(iconBuilder: OrbIcons.triangle(up: false), family: AppFamilies.sky, semanticLabel: 'aşağı', onTap: () {}),
              OrbButton(iconBuilder: OrbIcons.letter('G'), family: AppFamilies.sky, semanticLabel: 'Google', onTap: () {}),
            ],
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('G'), findsOneWidget);
      // Üçgen simge kutusu: lg orb'un simge boyutu (0.44 d).
      final box = tester.getSize(find.descendant(of: find.byType(OrbButton).first, matching: find.byType(CustomPaint)).last);
      expect(box.width, closeTo(OrbSize.lg.iconSize, 0.01));
      expect(OrbIcons.shadowFor(Colors.white), isNot(OrbIcons.shadowFor(Colors.black)));
    });
  });

  // -----------------------------------------------------------------------------------------
  // Arka plan
  // -----------------------------------------------------------------------------------------
  group('CircuitBackground', () {
    test('fotoğraf örtüsü açıkta eskisinden (.30/.50/.70) yoğun ve yukarıdan aşağı artar; koyuda da eskisinden zayıf değil', () {
      expect(CircuitBackground.lightScrim, hasLength(3));
      expect(CircuitBackground.darkScrim, hasLength(3));
      for (final scrim in [CircuitBackground.lightScrim, CircuitBackground.darkScrim]) {
        expect(scrim[0], lessThan(scrim[1]));
        expect(scrim[1], lessThan(scrim[2]));
        expect(scrim.every((a) => a > 0 && a < 1), isTrue);
      }
      const oldLight = [0.30, 0.50, 0.70];
      const oldDark = [0.50, 0.70, 0.88];
      for (var i = 0; i < 3; i++) {
        expect(CircuitBackground.lightScrim[i], greaterThanOrEqualTo(oldLight[i] + 0.15), reason: 'açık örtü belirgin yoğun (metin izlerle kesişmesin)');
        expect(CircuitBackground.darkScrim[i], greaterThanOrEqualTo(oldDark[i]));
      }
    });

    testWidgets('açık temada vektör çip gövdeleri neredeyse görünmez ("hayalet çip" yok); koyuda çip gövdesi hâlâ seçilir', (tester) async {
      Future<(double bodyContrast, double borderContrast)> measure(bool dark) async {
        const size = Size(400, 800);
        final bg = dark ? const Color(0xFF0B1120) : const Color(0xFFF8FAFC);
        final data = await tester.runAsync(() async {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          canvas.drawRect(Offset.zero & size, Paint()..color = bg);
          CircuitBoardPainter(isDark: dark).paint(canvas, size);
          final image = await recorder.endRecording().toImage(size.width.toInt(), size.height.toInt());
          final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
          image.dispose();
          return bytes!;
        });
        Color at(int x, int y) {
          final o = (y * 400 + x) * 4;
          return Color.fromARGB(255, data!.getUint8(o), data.getUint8(o + 1), data.getUint8(o + 2));
        }

        // Sol üst çip (w*0.08, h*0.06, 64x48 → x 32..96, y 48..96): gövde içi örnek ızgarasının MEDYAN kontrastı (iz
        // çizgilerinden/yuvarlak köşeden etkilenmesin) ve sol kenar çizgisinin (x ≈ 32) en yüksek kontrastı.
        final bodySamples = <double>[
          for (var x = 44; x <= 84; x += 10)
            for (var y = 60; y <= 88; y += 7) AppTheme.contrastRatio(at(x, y), bg),
        ]..sort();
        var border = 0.0;
        for (var x = 30; x <= 34; x++) {
          final c = AppTheme.contrastRatio(at(x, 48 + 30), bg);
          if (c > border) border = c;
        }
        return (bodySamples[bodySamples.length ~/ 2], border);
      }

      final light = await measure(false);
      final dark = await measure(true);
      expect(light.$1, lessThan(1.03), reason: 'açık: çip gövdesi zeminden neredeyse ayırt edilmez (şimdi ≈ 1.02, eskisi ≈ 1.04–1.05)');
      expect(light.$2, lessThan(1.10), reason: 'açık: çip kenarı belli belirsiz');
      expect(dark.$1, greaterThan(1.02), reason: 'koyu: çip gövdesi değişmedi (hafif seçilir)');
    });

    for (final brightness in [Brightness.dark, Brightness.light]) {
      testWidgets('${brightness.name}: görsel olmasa da (errorBuilder) hatasız kurulur; gradyan durakları sabitlere bağlı', (tester) async {
        await tester.pumpWidget(designHost(const CircuitBackground(child: SizedBox.expand()), brightness: brightness, center: false));
        expect(tester.takeException(), isNull);
        final container = tester.widgetList<Container>(find.byType(Container)).where((c) {
          final d = c.decoration;
          return d is BoxDecoration && d.gradient is LinearGradient && (d.gradient! as LinearGradient).colors.length == 3;
        }).first;
        final colors = ((container.decoration! as BoxDecoration).gradient! as LinearGradient).colors;
        final expected = brightness == Brightness.dark ? CircuitBackground.darkScrim : CircuitBackground.lightScrim;
        for (var i = 0; i < 3; i++) {
          expect(colors[i].a, closeTo(expected[i], 0.005));
        }
      });
    }
  });
}
